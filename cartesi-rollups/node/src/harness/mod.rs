// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! A deterministic chain for the node's own workers (item 3 of
//! docs/plans/test-strategy-reset.md). The test owns the only clock:
//! nothing free-runs or sleeps, the protocol counts blocks, and blocks are
//! mined only here. A round ticks the honest node's reader, runner and
//! epoch manager in lib.rs order and mines its wave into its own block.
//! Every mined block's receipts are checked, so an honest transaction that
//! reverts fails the test even though the node never estimates gas.
//!
//! The manager logs and drops dispute, settlement and refund planning
//! errors, so honest correctness is asserted through outcomes on chain,
//! not through tick results.
//!
//! The tests are ignored by plain cargo runs and run serially, in their own
//! process, by `just test-node-harness`: the v0.21 emulator takes exclusive
//! flocks on files it creates without close-on-exec, so an anvil spawned by
//! a concurrent test inherits them and later machine loads fail.

mod tests;

use alloy::{
    eips::BlockId,
    network::EthereumWallet,
    node_bindings::AnvilInstance,
    primitives::{Address, Bytes, FixedBytes},
    providers::{DynProvider, Provider, ProviderBuilder, ext::AnvilApi},
    signers::{Signer, local::PrivateKeySigner},
};
use anyhow::{Context, Result, ensure};
use cartesi_dave_contracts::dave_consensus::DaveConsensus;
use cartesi_prt_contracts::tournament::Tournament;
use cartesi_rollups_contracts::i_input_box::IInputBox;
use std::{sync::Arc, time::Duration};
use tempfile::TempDir;

use crate::{
    args::discover_deployed_tournament,
    blockchain_reader::{
        AddressBook, BlockchainReader,
        test_utils::{Deploy, deploy_app, program_path, spawn_anvil, wallet_provider},
    },
    chain::Chain,
    engine::TournamentGeometry,
    epoch_manager::EpochManager,
    machine_runner::MachineRunner,
    provider::TransactionLane,
    storage::Storage,
    tournament::EthArenaSender,
};

/// The honest node's anvil key.
pub(crate) const HONEST: usize = 0;
/// The key the test itself sends with (inputs, deployment).
const OPERATOR: usize = 9;

/// One mined transaction, as the chain recorded it.
#[derive(Debug, Clone)]
pub(crate) struct Mined {
    pub block: u64,
    pub from: Address,
    pub selector: Option<FixedBytes<4>>,
    pub success: bool,
}

pub(crate) struct World {
    anvil: AnvilInstance,
    provider: DynProvider,
    operator: DynProvider,
    pub chain: Chain,
    pub book: AddressBook,
    geometry: TournamentGeometry,
    /// Receipts are checked through this block.
    checked: u64,
    pub mined: Vec<Mined>,
}

impl World {
    /// Anvil over the devnet bundle with one Dave app on the echo
    /// template; `sentries` are anvil key indices.
    pub async fn spawn(sentries: &[usize], claim_staging_period: u64) -> Result<Self> {
        let anvil = spawn_anvil();
        let provider = ProviderBuilder::new()
            .connect_client(
                crate::blockchain_reader::test_utils::rpc_client_with_timeout(anvil.endpoint_url()),
            )
            .erased();
        // Reproducible blocks: one second apart from the bundle's last
        // timestamp, so inputs (InputBox stamps them) and every hash
        // derived from them repeat across runs.
        provider.anvil_set_block_timestamp_interval(1).await?;
        // Every node call carries a fixed 15M gas limit; let a whole wave
        // fit one block.
        provider.anvil_set_block_gas_limit(1_000_000_000).await?;

        let operator = wallet_provider(&anvil, OPERATOR);
        let deploy = Deploy {
            sentries: sentries.iter().map(|&key| anvil.addresses()[key]).collect(),
            claim_staging_period,
        };
        let book = deploy_app(&operator, &deploy)
            .await
            .map_err(|error| anyhow::anyhow!("deploying the app: {error}"))?;
        provider.anvil_set_auto_mine(false).await?;

        let geometry = discover_deployed_tournament(book.tournament_factory, &provider).await?;
        let chain = Chain::new(provider.clone(), vec![]);
        let checked = chain.latest_block_number().await?;
        let mut world = Self {
            anvil,
            provider,
            operator,
            chain,
            book,
            geometry,
            checked,
            mined: vec![],
        };

        // Finality is two blocks behind latest (--slots-in-an-epoch 1);
        // every wait below depends on it, so check it.
        world.mine(3).await?;
        let latest = world.chain.latest_block_number().await?;
        ensure!(
            world.chain.finalized_block_number().await? == latest - 2,
            "anvil's finalized head is not latest - 2"
        );
        Ok(world)
    }

    pub fn address(&self, key: usize) -> Address {
        self.anvil.addresses()[key]
    }

    pub async fn latest(&self) -> Result<u64> {
        self.chain.latest_block_number().await
    }

    /// Mines `blocks` blocks, then checks every new receipt: an honest
    /// transaction must not revert.
    pub async fn mine(&mut self, blocks: u64) -> Result<()> {
        self.provider.anvil_mine(Some(blocks), None).await?;
        let latest = self.latest().await?;
        for block in self.checked + 1..=latest {
            let receipts = self
                .provider
                .get_block_receipts(BlockId::number(block))
                .await?
                .unwrap_or_default();
            for receipt in receipts {
                let input = self
                    .provider
                    .get_transaction_by_hash(receipt.transaction_hash)
                    .await?
                    .map(|tx| Bytes::copy_from_slice(alloy::consensus::Transaction::input(&tx)))
                    .unwrap_or_default();
                let mined = Mined {
                    block,
                    from: receipt.from,
                    selector: (input.len() >= 4).then(|| FixedBytes::from_slice(&input[..4])),
                    success: receipt.status(),
                };
                ensure!(
                    mined.success || mined.from != self.address(HONEST),
                    "an honest transaction reverted: {mined:?}"
                );
                self.mined.push(mined);
            }
        }
        self.checked = latest;
        Ok(())
    }

    /// Mines up to and including `block`.
    pub async fn mine_to(&mut self, block: u64) -> Result<()> {
        let latest = self.latest().await?;
        if block > latest {
            self.mine(block - latest).await?;
        }
        Ok(())
    }

    /// The honest transactions with this selector that mined.
    pub fn honest_calls(&self, selector: FixedBytes<4>) -> Vec<&Mined> {
        let honest = self.address(HONEST);
        self.mined
            .iter()
            .filter(|mined| mined.from == honest && mined.selector == Some(selector))
            .collect()
    }

    /// Adds an input from the operator key and mines it.
    pub async fn add_input(&mut self, payload: Vec<u8>) -> Result<()> {
        let pending = IInputBox::new(self.book.input_box, &self.operator)
            .addInput(self.book.app, payload.into())
            .send()
            .await?;
        let hash = *pending.tx_hash();
        self.mine(1).await?;
        let receipt = self
            .provider
            .get_transaction_receipt(hash)
            .await?
            .context("the input did not mine")?;
        ensure!(receipt.status(), "addInput reverted");
        Ok(())
    }

    /// Drops every transaction still in the pool, as if the sender had
    /// crashed before they propagated.
    pub async fn drop_pending(&self) -> Result<()> {
        self.provider.anvil_drop_all_transactions().await?;
        Ok(())
    }

    pub fn consensus(&self) -> DaveConsensus::DaveConsensusInstance<DynProvider> {
        DaveConsensus::new(self.book.consensus, self.provider.clone())
    }

    /// The EpochSealed events so far, oldest first.
    pub async fn sealed_epochs(&self) -> Result<Vec<DaveConsensus::EpochSealed>> {
        Ok(self
            .consensus()
            .EpochSealed_filter()
            .from_block(0)
            .query()
            .await?
            .into_iter()
            .map(|(event, _)| event)
            .collect())
    }

    /// The block from which the current sealed epoch's root tournament
    /// takes no more joins and, with a lone claimer, can be decided.
    pub async fn root_closes_at(&self) -> Result<u64> {
        let sealed = self.consensus().getCurrentSealedEpoch().call().await?;
        let descriptor = Tournament::new(sealed.tournament, self.provider.clone())
            .tournamentDescriptor()
            .call()
            .await?;
        Ok(descriptor.startInstant + descriptor.allowance)
    }

    /// The honest node over a fresh state directory.
    pub async fn honest_node(&self) -> Result<Node> {
        let state_dir = tempfile::tempdir()?;
        Storage::initialize(
            state_dir.path(),
            &program_path().join("machine-image"),
            self.book.genesis_block_number,
            self.book.app,
            self.book.consensus,
            &self.geometry,
        )?;
        Node::start(self, state_dir)
    }

    fn lane(&self, key: usize) -> TransactionLane {
        let mut signer: PrivateKeySigner = self.anvil.keys()[key].clone().into();
        signer.set_chain_id(Some(self.anvil.chain_id()));
        TransactionLane::new(
            self.provider.clone(),
            self.provider.clone(),
            self.anvil.chain_id(),
            EthereumWallet::from(signer),
        )
    }
}

/// The honest node's three workers over one state directory, driven tick
/// by tick in lib.rs order.
pub(crate) struct Node {
    state_dir: TempDir,
    reader: BlockchainReader,
    runner: MachineRunner,
    manager: EpochManager<EthArenaSender>,
}

impl Node {
    fn start(world: &World, state_dir: TempDir) -> Result<Self> {
        // The startup ritual lib.rs runs before spawning the workers.
        {
            let mut storage = Storage::new(state_dir.path())?;
            storage.sweep_settled_epoch_scratch()?;
            storage.sweep_stale_staging()?;
        }
        let reader =
            BlockchainReader::new(Storage::new(state_dir.path())?, world.book, Duration::ZERO);
        let runner = MachineRunner::new(Storage::new(state_dir.path())?, Duration::ZERO)?;
        let manager = EpochManager::new(
            Arc::new(EthArenaSender::new(world.provider.clone())),
            world.lane(HONEST),
            world.book.consensus,
            world.address(HONEST),
            Storage::new(state_dir.path())?,
            Duration::ZERO,
        )?;
        Ok(Self {
            state_dir,
            reader,
            runner,
            manager,
        })
    }

    /// One pass of every worker; the wave stays in the pool.
    pub async fn tick(&mut self, world: &World) -> Result<()> {
        self.reader.tick(&world.chain).await?;
        self.runner.process_rollup()?;
        self.manager.tick(&world.chain).await?;
        Ok(())
    }

    /// A tick whose wave mines into its own block.
    pub async fn turn(&mut self, world: &mut World) -> Result<()> {
        self.tick(world).await?;
        world.mine(1).await
    }

    /// Turns until `done` holds, at most `rounds` times.
    pub async fn run_until(
        &mut self,
        world: &mut World,
        rounds: usize,
        mut done: impl FnMut(&World, &mut Storage) -> Result<bool>,
    ) -> Result<()> {
        let mut storage = Storage::new(self.state_dir.path())?;
        for _ in 0..rounds {
            if done(world, &mut storage)? {
                return Ok(());
            }
            self.turn(world).await?;
        }
        ensure!(
            done(world, &mut storage)?,
            "not done after {rounds} rounds; latest block {}, unfinished epoch {:?}, \
             sealed epochs {}, last mined {:?}",
            world.latest().await?,
            storage.unfinished_epoch()?.map(|epoch| epoch.epoch_number),
            world.sealed_epochs().await?.len(),
            world.mined.last(),
        );
        Ok(())
    }

    /// Drops every worker and starts them again over the same state, as
    /// a process restart would.
    pub fn restart(self, world: &World) -> Result<Self> {
        let Node { state_dir, .. } = self;
        Node::start(world, state_dir)
    }
}
