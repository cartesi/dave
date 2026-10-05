// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! A deterministic chain for the node's own workers (docs/test-harness.md).
//! The test owns the only clock:
//! nothing free-runs or sleeps, the protocol counts blocks, and blocks are
//! mined only here. A round ticks the honest node's reader, runner and
//! epoch manager in lib.rs order and mines its wave into its own block.
//! Every mined block's receipts are checked, so an honest transaction that
//! reverts fails the test, and so does one the lane declines to send
//! because it already reverts at latest.
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
    engine::{Tail, TournamentGeometry},
    epoch_manager::EpochManager,
    hero::Hero,
    machine_runner::MachineRunner,
    provider::{SendVerdict, TransactionLane},
    storage::{Storage, Template},
    sync::ShutdownSignal,
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
        // derived from them repeat across runs. Without the reset, the
        // first block after loading the state takes the wall clock.
        let head = provider
            .get_block(BlockId::latest())
            .await?
            .context("anvil has no head")?;
        provider.anvil_set_time(head.header.timestamp).await?;
        provider.anvil_set_block_timestamp_interval(1).await?;
        // Gas limits are padded estimates, 15M on fallback; let a whole wave
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

    /// The deployed tournament's level count.
    pub fn levels(&self) -> usize {
        self.geometry.levels().len()
    }

    /// The deployed tournament's heights, root first.
    pub fn geometry_heights(&self) -> Vec<u64> {
        self.geometry
            .levels()
            .iter()
            .map(|level| level.height)
            .collect()
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

    /// Every mined transaction, one line each: block, key, verb and
    /// whether it reverted. Runs that do not finish print it.
    pub fn trace(&self) -> String {
        use alloy::sol_types::SolCall;
        use cartesi_prt_contracts::tournament::Tournament as T;
        let verbs = [
            (T::joinTournamentCall::SELECTOR, "join"),
            (T::advanceMatchCall::SELECTOR, "advance"),
            (
                T::sealInnerMatchAndCreateInnerTournamentCall::SELECTOR,
                "seal inner",
            ),
            (T::sealLeafMatchCall::SELECTOR, "seal leaf"),
            (T::winLeafMatchCall::SELECTOR, "win leaf"),
            (T::winMatchByTimeoutCall::SELECTOR, "win by timeout"),
            (T::winInnerTournamentCall::SELECTOR, "win inner"),
            (T::eliminateMatchByTimeoutCall::SELECTOR, "eliminate match"),
            (T::eliminateInnerTournamentCall::SELECTOR, "eliminate inner"),
            (T::tryRecoveringBondCall::SELECTOR, "recover bond"),
            (
                DaveConsensus::submitSentryClaimCall::SELECTOR,
                "sentry claim",
            ),
            (DaveConsensus::stageTournamentResultCall::SELECTOR, "stage"),
            (
                DaveConsensus::acceptStagedTournamentResultCall::SELECTOR,
                "accept",
            ),
        ];
        self.mined
            .iter()
            .map(|mined| {
                let key = (0..10).find(|&key| self.address(key) == mined.from);
                let verb = verbs
                    .iter()
                    .find(|(selector, _)| mined.selector == Some(FixedBytes(*selector)))
                    .map_or("other", |(_, verb)| verb);
                let reverted = if mined.success { "" } else { " (reverted)" };
                format!("{} key {key:?} {verb}{reverted}\n", mined.block)
            })
            .collect()
    }

    /// The honest transactions with this selector that mined.
    pub fn honest_calls(&self, selector: FixedBytes<4>) -> Vec<&Mined> {
        self.calls(HONEST, selector)
    }

    /// Key `key`'s transactions with this selector that mined.
    pub fn calls(&self, key: usize, selector: FixedBytes<4>) -> Vec<&Mined> {
        let from = self.address(key);
        self.mined
            .iter()
            .filter(|mined| mined.from == from && mined.selector == Some(selector))
            .collect()
    }

    fn tournament(&self, address: Address) -> Tournament::TournamentInstance<DynProvider> {
        Tournament::new(address, self.provider.clone())
    }

    pub async fn matches_created(
        &self,
        tournament: Address,
    ) -> Result<Vec<Tournament::MatchCreated>> {
        let instance = self.tournament(tournament);
        let filter = instance.MatchCreated_filter().from_block(0);
        Ok(filter
            .query()
            .await?
            .into_iter()
            .map(|(event, _)| event)
            .collect())
    }

    pub async fn matches_deleted(
        &self,
        tournament: Address,
    ) -> Result<Vec<Tournament::MatchDeleted>> {
        let instance = self.tournament(tournament);
        let filter = instance.MatchDeleted_filter().from_block(0);
        Ok(filter
            .query()
            .await?
            .into_iter()
            .map(|(event, _)| event)
            .collect())
    }

    /// Joins, with the block each mined in.
    pub async fn commitments_joined(
        &self,
        tournament: Address,
    ) -> Result<Vec<(Tournament::CommitmentJoined, u64)>> {
        let instance = self.tournament(tournament);
        let filter = instance.CommitmentJoined_filter().from_block(0);
        Ok(filter
            .query()
            .await?
            .into_iter()
            .map(|(event, log)| (event, log.block_number.unwrap_or_default()))
            .collect())
    }

    /// Bond recoveries, with the block each mined in.
    pub async fn bonds_recovered(
        &self,
        tournament: Address,
    ) -> Result<Vec<(Tournament::BondRecovered, u64)>> {
        let instance = self.tournament(tournament);
        let filter = instance.BondRecovered_filter().from_block(0);
        Ok(filter
            .query()
            .await?
            .into_iter()
            .map(|(event, log)| (event, log.block_number.unwrap_or_default()))
            .collect())
    }

    /// The deepest tournament below `tournament`, following the last child
    /// created at each level.
    pub async fn deepest(&self, tournament: Address) -> Result<Address> {
        let mut deepest = tournament;
        while let Some(child) = self.inner_tournaments(deepest).await?.last() {
            deepest = child.childTournament;
        }
        Ok(deepest)
    }

    pub async fn standing(
        &self,
        tournament: Address,
        commitment: FixedBytes<32>,
    ) -> Result<cartesi_prt_contracts::tournament::ITournament::CommitmentStandingView> {
        Ok(self
            .tournament(tournament)
            .commitmentStanding(commitment)
            .call()
            .await?)
    }

    /// The timeout outcome the contract classifies for a match at `block`
    /// (ITournament's MatchTimeoutOutcome, as its byte).
    pub async fn timeout_outcome_at(
        &self,
        tournament: Address,
        created: &Tournament::MatchCreated,
        block: u64,
    ) -> Result<u8> {
        let id = cartesi_prt_contracts::tournament::Match::Id {
            commitmentOne: created.one,
            commitmentTwo: created.two,
        };
        let classified = self
            .tournament(tournament)
            .classifyMatchTimeout(id)
            .block(BlockId::number(block))
            .call()
            .await?;
        Ok(classified.outcome)
    }

    pub async fn balance(&self, address: Address) -> Result<alloy::primitives::U256> {
        Ok(self.provider.get_balance(address).await?)
    }

    pub async fn inner_tournaments(
        &self,
        tournament: Address,
    ) -> Result<Vec<Tournament::NewInnerTournament>> {
        let instance = self.tournament(tournament);
        let filter = instance.NewInnerTournament_filter().from_block(0);
        Ok(filter
            .query()
            .await?
            .into_iter()
            .map(|(event, _)| event)
            .collect())
    }

    /// Whether the InputBox would take this payload, simulated as a call.
    pub async fn accepts_input(&self, payload: Vec<u8>) -> bool {
        IInputBox::new(self.book.input_box, &self.operator)
            .addInput(self.book.app, payload.into())
            .call()
            .await
            .is_ok()
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
            &Template::inspect(&program_path().join("machine-image"))?,
            // Anvil does not reorg, so a sample after discovery is as good.
            self.book
                .initial_watermark(self.chain.finalized_block_number().await?),
            self.book.app,
            self.book.consensus,
            self.anvil.chain_id(),
            &self.geometry,
        )?;
        Node::start(self, state_dir)
    }

    /// An adversary on anvil key `key` for the honest node's current
    /// epoch, which the node's runner must have rolled: the production
    /// Hero over the node's store, diverging from transition `tail.from`
    /// on (see Tail).
    pub fn adversary(
        &self,
        node: &Node,
        key: usize,
        tail: Tail,
        policy: Policy,
    ) -> Result<Adversary> {
        // A private copy of the node's store, as an independent sybil would
        // have: the adversary reads the node's rolled material, but its
        // event cache, quartet rows and write-backs stay out of the node's
        // store, so the node computes and harvests everything itself.
        // Snapshot rows keep pointing at the node's immutable snapshots.
        let state_dir = tempfile::tempdir()?;
        std::fs::create_dir(state_dir.path().join("snapshots"))?;
        rusqlite::Connection::open(crate::storage::open::db_path(node.state_dir.path()))?.execute(
            "VACUUM INTO ?1",
            [crate::storage::open::db_path(state_dir.path())
                .to_string_lossy()
                .into_owned()],
        )?;
        let mut storage = Storage::new(state_dir.path())?;
        let epoch = storage.unfinished_epoch()?.context("no epoch to dispute")?;
        ensure!(
            storage.settlement_info(epoch.epoch_number)?.is_some(),
            "the node has not rolled epoch {}",
            epoch.epoch_number
        );
        let engine_dir = state_dir.path().join("engine");
        let hero = Hero::with_tail(
            Arc::new(EthArenaSender::new(self.provider.clone())),
            self.chain.clone(),
            epoch.root_tournament,
            epoch.block_created_number,
            storage,
            epoch.epoch_number,
            engine_dir,
            tail,
        )?;
        Ok(Adversary {
            hero,
            lane: self.lane(key),
            policy,
            stopped: false,
            held: None,
            _state_dir: state_dir,
            errors: vec![],
        })
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
        let runner = MachineRunner::new(
            Storage::new(state_dir.path())?,
            Duration::ZERO,
            ShutdownSignal::default(),
        )?;
        let manager = EpochManager::new(
            Arc::new(EthArenaSender::new(world.provider.clone())),
            world.lane(HONEST),
            world.book.consensus,
            world.address(HONEST),
            Storage::new(state_dir.path())?,
            Duration::ZERO,
            ShutdownSignal::default(),
        );
        Ok(Self {
            state_dir,
            reader,
            runner,
            manager,
        })
    }

    /// One pass of every worker; the wave stays in the pool.
    pub async fn tick(&mut self, world: &World) -> Result<()> {
        while !self.reader.tick(&world.chain).await? {}
        self.runner.process_rollup()?;
        let ticked = self.manager.tick(&world.chain).await?;
        let reverting: Vec<_> = ticked
            .reports
            .iter()
            .filter(|report| report.verdict == SendVerdict::Reverts)
            .map(|report| report.label.as_str())
            .collect();
        ensure!(
            reverting.is_empty(),
            "honest actions revert at latest: {reverting:?}"
        );
        Ok(())
    }

    /// Ingests and executes until the runner has rolled `epoch`, without
    /// the epoch manager: the node takes no action, so adversaries can
    /// move first.
    pub async fn roll(&mut self, world: &mut World, epoch: u64) -> Result<()> {
        let mut storage = Storage::new(self.state_dir.path())?;
        for _ in 0..16 {
            while !self.reader.tick(&world.chain).await? {}
            self.runner.process_rollup()?;
            if storage.settlement_info(epoch)?.is_some() {
                return Ok(());
            }
            world.mine(1).await?;
        }
        anyhow::bail!("the runner did not roll epoch {epoch}")
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
        done: impl FnMut(&World, &mut Storage) -> Result<bool>,
    ) -> Result<()> {
        self.run_with(world, &mut [], rounds, done).await
    }

    /// Rounds until `done` holds, at most `rounds` of them: the node's
    /// turn, then each adversary's in order.
    pub async fn run_with(
        &mut self,
        world: &mut World,
        adversaries: &mut [&mut Adversary],
        rounds: usize,
        mut done: impl FnMut(&World, &mut Storage) -> Result<bool>,
    ) -> Result<()> {
        let mut storage = Storage::new(self.state_dir.path())?;
        for _ in 0..rounds {
            if done(world, &mut storage)? {
                return Ok(());
            }
            self.turn(world).await?;
            for adversary in adversaries.iter_mut() {
                adversary.turn(world).await?;
            }
        }
        ensure!(
            done(world, &mut storage)?,
            "not done after {rounds} rounds; latest block {}, unfinished epoch {:?}, \
             sealed epochs {}; mined:\n{}",
            world.latest().await?,
            storage.unfinished_epoch()?.map(|epoch| epoch.epoch_number),
            world.sealed_epochs().await?.len(),
            world.trace(),
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

/// What an adversary submits of the waves its Hero plans.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Policy {
    /// Every wave.
    Rational,
    /// Waves through the first request with this label, then nothing.
    StopAfter(&'static str),
    /// Every wave until one carries this label; that wave is held for the
    /// test to release, and nothing follows it.
    Hold(&'static str),
}

/// The production Hero over a test-only tail overlay, on its own key. It
/// has no reader, runner or manager: it disputes the honest node's epoch
/// from a copy of the honest node's store.
pub(crate) struct Adversary {
    hero: Hero<EthArenaSender>,
    lane: TransactionLane,
    policy: Policy,
    stopped: bool,
    held: Option<Vec<crate::provider::LaneRequest>>,
    _state_dir: TempDir,
    /// Its Hero's errors. A patched leaf cannot be proven, so a rational
    /// adversary errors whenever it tries.
    pub errors: Vec<String>,
}

impl Adversary {
    /// Whether a Hold policy is holding its wave.
    pub fn holding(&self) -> bool {
        self.held.is_some()
    }

    /// Submits the held wave and mines it into its own block.
    pub async fn release(&mut self, world: &mut World) -> Result<()> {
        let wave = self.held.take().context("nothing held")?;
        self.lane.submit_wave(wave).await?;
        world.mine(1).await
    }

    /// Abandons the dispute: no further ticks.
    pub fn stop(&mut self) {
        self.stopped = true;
    }

    /// One Hero tick under the policy; a submitted wave mines into its
    /// own block.
    pub async fn turn(&mut self, world: &mut World) -> Result<()> {
        if self.stopped {
            return Ok(());
        }
        let mut wave = match self.hero.tick().await {
            Ok(tick) => tick.into_wave(),
            Err(error) => {
                self.errors.push(format!("{error:#}"));
                return Ok(());
            }
        };
        if let Policy::StopAfter(label) = self.policy
            && let Some(at) = wave.iter().position(|(request, _)| request == label)
        {
            wave.truncate(at + 1);
            self.stopped = true;
        }
        if let Policy::Hold(label) = self.policy
            && wave.iter().any(|(request, _)| request == label)
        {
            self.held = Some(wave);
            self.stopped = true;
            return Ok(());
        }
        if wave.is_empty() {
            return Ok(());
        }
        self.lane.submit_wave(wave).await?;
        world.mine(1).await
    }
}
