// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use anyhow::{Context, Result};

use crate::chain::Chain;
use crate::sync::ShutdownSignal;
use alloy::{
    hex::ToHexExt,
    primitives::{Address, B256, U256},
    providers::Provider,
};
use cartesi_machine::types::Hash;
use log::{debug, info, trace};
use std::{fmt, iter::Peekable, time::Duration};

use crate::storage::{Epoch, Input, InputId, Storage};
use cartesi_dave_contracts::dave_consensus::DaveConsensus::{self, EpochSealed};
use cartesi_rollups_contracts::{
    i_application::IApplication,
    i_input_box::IInputBox::{self, InputAdded},
};

#[derive(Debug, Clone, Copy)]
pub struct AddressBook {
    /// address of app
    pub app: Address,

    /// address of Dave consensus
    pub consensus: Address,

    /// address of tournament factory
    pub tournament_factory: Address,

    /// address of input box
    pub input_box: Address,

    /// initial state hash of application
    pub initial_hash: Hash,

    /// earliest block number where contracts exist
    pub genesis_block_number: u64,
}

impl fmt::Display for AddressBook {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "App Address: {}", self.app)?;
        writeln!(f, "Consensus Address: {}", self.consensus)?;
        writeln!(f, "Tournament Factory Address: {}", self.tournament_factory)?;
        writeln!(f, "Input Box Address: {}", self.input_box)?;
        writeln!(
            f,
            "Initial Hash: 0x{}",
            alloy::hex::encode(self.initial_hash)
        )?;
        writeln!(f, "Genesis Block Number: {}", self.genesis_block_number)?;
        Ok(())
    }
}

impl AddressBook {
    /// Fetches the other addresses from the application. The caller names
    /// the flag: every failure here means `app` is not a Dave application
    /// on this chain, or the endpoint is failing.
    pub async fn new(app: Address, provider: &impl Provider) -> Result<Self> {
        let application_contract = IApplication::new(app, provider);

        let consensus = application_contract
            .getOutputsMerkleRootValidator()
            .call()
            .await
            .context("failed to query the application's consensus")?;

        let consensus_contract = DaveConsensus::new(consensus, provider);
        let input_box = consensus_contract
            .getInputBox()
            .call()
            .await
            .with_context(|| format!("failed to query the input box of consensus {consensus}"))?;
        let tournament_factory = consensus_contract
            .getTournamentFactory()
            .call()
            .await
            .with_context(|| {
                format!("failed to query the tournament factory of consensus {consensus}")
            })?;

        let initial_hash = Self::initial_hash(consensus, provider).await?;

        let input_box_created_block: u64 = IInputBox::new(input_box, provider)
            .getDeploymentBlockNumber()
            .call()
            .await
            .with_context(|| {
                format!("failed to query the deployment block of input box {input_box}")
            })?
            .try_into()
            .with_context(|| {
                format!("input box {input_box} reports a deployment block beyond u64")
            })?;

        Ok(Self {
            app,
            consensus,
            tournament_factory,
            input_box,
            genesis_block_number: input_box_created_block,
            initial_hash,
        })
    }

    /// The initial state from epoch 0's EpochSealed, which the consensus
    /// emits in its own deployment block.
    pub async fn initial_hash(consensus: Address, provider: &impl Provider) -> Result<Hash> {
        let consensus_contract = DaveConsensus::new(consensus, provider);

        let consensus_created_block: u64 = consensus_contract
            .getDeploymentBlockNumber()
            .call()
            .await
            .with_context(|| {
                format!("failed to query the deployment block of consensus {consensus}")
            })?
            .try_into()
            .with_context(|| {
                format!("consensus {consensus} reports a deployment block beyond u64")
            })?;

        debug!(
            "consensus created {} at {}",
            consensus_created_block, consensus
        );

        let sealed_epochs = consensus_contract
            .EpochSealed_filter()
            .address(consensus)
            .topic1(B256::ZERO)
            .from_block(consensus_created_block)
            .to_block(consensus_created_block)
            .query()
            .await
            .context("failed to query the EpochSealed log of epoch 0")?;
        // The deployment block is `block.number`. Where that is not the log
        // block coordinate (Arbitrum reports the parent chain's), the query
        // looks in the wrong block.
        let (epoch_zero, _) = sealed_epochs.first().with_context(|| {
            format!(
                "no EpochSealed for epoch 0 at consensus {consensus}'s deployment block \
                 {consensus_created_block} (its block.number); on chains whose block.number \
                 is not the log block coordinate, such as Arbitrum, the node cannot locate \
                 genesis"
            )
        })?;

        Ok(epoch_zero.initialMachineStateHash.into())
    }
}

/// Finalized blocks ingested and committed per tick: the in-memory bound on
/// a cold start or a long downtime, and about the `eth_getLogs` range many
/// providers already cap, so chunking adds few calls.
const INGEST_CHUNK_BLOCKS: u64 = 10_000;

pub struct BlockchainReader {
    storage: Storage,
    address_book: AddressBook,
    sleep_duration: Duration,
    chunk_blocks: u64,
}

impl BlockchainReader {
    pub fn new(storage: Storage, address_book: AddressBook, sleep_duration: Duration) -> Self {
        Self {
            storage,
            address_book,
            sleep_duration,
            chunk_blocks: INGEST_CHUNK_BLOCKS,
        }
    }

    #[cfg(test)]
    pub(crate) fn with_chunk_blocks(mut self, chunk_blocks: u64) -> Self {
        assert!(chunk_blocks >= 1, "a chunk must cover a block");
        self.chunk_blocks = chunk_blocks;
        self
    }

    pub async fn execution_loop(mut self, shutdown: ShutdownSignal, chain: Chain) -> Result<()> {
        loop {
            // A failed tick is retried, not fatal: the tick is
            // re-derived from finalized state, so a provider hiccup
            // costs one polling interval. This worker used to die on
            // the first transient error - the exact failure class the
            // epoch manager's 2026-07-10 fix addressed. A stop drops the
            // tick in flight, which writes nothing: its one write, the
            // chunk's commit, is synchronous and follows every await.
            let caught_up = tokio::select! { biased;
                _ = shutdown.requested() => break Ok(()),
                ticked = self.tick(&chain) => ticked.unwrap_or_else(|e| {
                    log::warn!("blockchain read failed, retrying next tick: {e:#}");
                    true
                }),
            };

            // Catch up chunk by chunk without a polling sleep, observing
            // shutdown between chunks.
            if !caught_up && !shutdown.is_requested() {
                continue;
            }
            tokio::select! { biased;
                _ = shutdown.requested() => break Ok(()),
                _ = tokio::time::sleep(self.sleep_duration) => {}
            }
        }
    }

    /// Ingests and commits the next chunk of finalized blocks; true once
    /// ingestion has reached the finalized head. A chunk end is just another
    /// cut like the finalized head: the next chunk reseeds its numbering from
    /// storage, as the next tick does.
    pub(crate) async fn tick(&mut self, chain: &Chain) -> Result<bool> {
        let finalized = chain.finalized_block_number().await?;
        let processed = self.storage.latest_processed_block()?;
        if finalized <= processed {
            return Ok(true);
        }

        let chunk_end = finalized.min(processed.saturating_add(self.chunk_blocks));
        self.advance(chain, processed, chunk_end).await?;
        Ok(chunk_end == finalized)
    }

    async fn advance(&mut self, chain: &Chain, prev_block: u64, current_block: u64) -> Result<()> {
        let (inputs, epochs) = self
            .collect_events(chain, prev_block, current_block)
            .await?;

        self.storage.insert_consensus_data(
            current_block,
            inputs.iter().collect::<Vec<&Input>>().into_iter(),
            epochs.iter().collect::<Vec<&Epoch>>().into_iter(),
        )?;

        Ok(())
    }

    async fn collect_events(
        &mut self,
        chain: &Chain,
        prev_block: u64,
        current_block: u64,
    ) -> Result<(Vec<Input>, Vec<Epoch>)> {
        // read sealed epochs from blockchain
        let sealed_epochs: Vec<Epoch> = self
            .collect_sealed_epochs(chain, prev_block, current_block)
            .await?;

        let last_sealed_epoch_opt = self.storage.last_sealed_epoch()?;
        let mut merged_sealed_epochs = Vec::new();
        if let Some(last_sealed_epoch) = last_sealed_epoch_opt {
            merged_sealed_epochs.push(last_sealed_epoch);
        }
        merged_sealed_epochs.extend(sealed_epochs.clone());
        let merged_sealed_epochs_iter = merged_sealed_epochs
            .iter()
            .collect::<Vec<&Epoch>>()
            .into_iter();

        // read inputs from blockchain
        let inputs = self
            .collect_inputs(chain, prev_block, current_block, merged_sealed_epochs_iter)
            .await?;

        Ok((inputs, sealed_epochs))
    }

    async fn collect_sealed_epochs(
        &mut self,
        chain: &Chain,
        prev_block: u64,
        current_block: u64,
    ) -> Result<Vec<Epoch>> {
        Ok(chain
            .decoded_logs::<EpochSealed>(
                self.address_book.consensus,
                None,
                // blocks are inclusive on both ends
                prev_block + 1,
                current_block,
            )
            .await?
            .iter()
            .map(|(e, meta)| {
                let epoch = Epoch {
                    epoch_number: u64::try_from(e.epochNumber)
                        .expect("fail to convert epoch number"),
                    input_index_boundary: u64::try_from(e.inputIndexUpperBound)
                        .expect("fail to convert epoch boundary"),
                    root_tournament: e.tournament,
                    block_created_number: meta.block_number.expect("block number should exist"),
                };
                info!(
                    "epoch received: epoch_number {}, input_index_boundary {}, root_tournament {}",
                    epoch.epoch_number, epoch.input_index_boundary, epoch.root_tournament
                );
                epoch
            })
            .collect())
    }

    async fn collect_inputs(
        &mut self,
        chain: &Chain,
        prev_block: u64,
        current_block: u64,
        sealed_epochs_iter: impl Iterator<Item = &Epoch>,
    ) -> Result<Vec<Input>> {
        // read new inputs from blockchain
        let input_events: Vec<_> = chain
            .decoded_logs::<InputAdded>(
                self.address_book.input_box,
                Some(&self.address_book.app.into_word().into()),
                // blocks are inclusive on both ends
                prev_block + 1,
                current_block,
            )
            .await?
            .into_iter()
            .map(|i| i.0)
            .collect();

        let last_input = self.storage.last_input()?;
        // Inputs are numbered here, so a log the provider leaves out of a
        // finalized range would silently shift every later input and
        // commitment. Each event carries its own index; check them.
        let mut next_index = self.storage.total_input_count()?;

        let (mut next_input_index_in_epoch, mut last_input_epoch_number) = {
            match last_input {
                // continue inserting inputs from where it was left
                Some(input) => (input.input_index_in_epoch + 1, input.epoch_number),
                // first ever input for the application
                None => (0, 0),
            }
        };

        let mut inputs = vec![];
        let mut input_events_peekable = input_events.iter().peekable();
        for epoch in sealed_epochs_iter {
            if last_input_epoch_number > epoch.epoch_number {
                continue;
            }
            // iterate through newly sealed epochs, fill in the inputs accordingly
            let inputs_of_epoch = construct_input_ids(
                epoch.epoch_number,
                epoch.input_index_boundary,
                &mut next_input_index_in_epoch,
                &mut next_index,
                &mut input_events_peekable,
            )?;

            inputs.extend(inputs_of_epoch);
            last_input_epoch_number = epoch.epoch_number + 1;
        }

        // all remaining inputs belong to an epoch that's not sealed yet
        let inputs_of_epoch = construct_input_ids(
            last_input_epoch_number,
            u64::MAX,
            &mut next_input_index_in_epoch,
            &mut next_index,
            &mut input_events_peekable,
        )?;

        inputs.extend(inputs_of_epoch);

        Ok(inputs)
    }
}

#[cfg(test)]
pub(crate) mod test_utils;

/// Numbers the events of one epoch, up to its input upper bound
/// (`u64::MAX` while open), checking each event's own index against the
/// next expected one and a sealed epoch's end against its bound: a
/// provider that drops a log fails the tick before anything is stored.
fn construct_input_ids<'a>(
    epoch_number: u64,
    input_index_boundary: u64,
    next_input_index_in_epoch: &mut u64,
    next_index: &mut u64,
    input_events_peekable: &mut Peekable<impl Iterator<Item = &'a InputAdded>>,
) -> Result<Vec<Input>> {
    let mut inputs = vec![];

    while let Some(input_added) = input_events_peekable.peek() {
        if input_added.index >= U256::from(input_index_boundary) {
            break;
        }
        anyhow::ensure!(
            input_added.index == U256::from(*next_index),
            "InputAdded index {} where {} was expected: incomplete logs from the provider",
            input_added.index,
            next_index
        );
        let input = Input {
            id: InputId {
                epoch_number,
                input_index_in_epoch: *next_input_index_in_epoch,
            },
            data: input_added.input.to_vec(),
        };
        info!(
            "input received: epoch_number {}, input_index {}",
            input.id.epoch_number, input.id.input_index_in_epoch,
        );
        trace!("input data 0x{}", input.data.encode_hex());

        input_events_peekable.next();
        *next_input_index_in_epoch += 1;
        *next_index += 1;
        inputs.push(input);
    }
    if input_index_boundary != u64::MAX {
        anyhow::ensure!(
            *next_index == input_index_boundary,
            "epoch {epoch_number} seals at input {input_index_boundary}, but only {next_index} \
             inputs arrived: incomplete logs from the provider"
        );
    }
    // input index in epoch should be reset when a new epoch starts
    *next_input_index_in_epoch = 0;

    Ok(inputs)
}

#[cfg(test)]
mod input_numbering_tests {
    use super::*;

    fn events(indices: &[u64]) -> Vec<InputAdded> {
        indices
            .iter()
            .map(|&index| InputAdded {
                appContract: Address::ZERO,
                index: U256::from(index),
                input: vec![index as u8].into(),
            })
            .collect()
    }

    /// Numbers `indices` as one sealed epoch (bound `Some`) or the open
    /// one, starting from global input `first`.
    fn number(indices: &[u64], first: u64, bound: Option<u64>) -> Result<Vec<Input>> {
        let events = events(indices);
        let (mut in_epoch, mut next) = (0, first);
        construct_input_ids(
            3,
            bound.unwrap_or(u64::MAX),
            &mut in_epoch,
            &mut next,
            &mut events.iter().peekable(),
        )
    }

    #[test]
    fn contiguous_inputs_are_numbered_within_their_epoch() {
        let inputs = number(&[5, 6, 7], 5, Some(8)).unwrap();
        let ids: Vec<u64> = inputs.iter().map(|i| i.id.input_index_in_epoch).collect();
        assert_eq!(ids, [0, 1, 2]);
        assert!(inputs.iter().all(|i| i.id.epoch_number == 3));
        assert_eq!(number(&[5, 6], 5, None).unwrap().len(), 2);
    }

    #[test]
    fn a_missing_log_fails_instead_of_shifting_later_inputs() {
        assert!(number(&[5, 7], 5, None).is_err(), "an interior gap");
        assert!(number(&[6, 7], 5, None).is_err(), "a gap before the first");
        assert!(number(&[5, 5], 5, None).is_err(), "a duplicate");
        assert!(
            number(&[5, 6], 5, Some(8)).is_err(),
            "a sealed epoch missing its last input"
        );
    }
}

#[cfg(test)]
mod blockchain_reader_tests {
    use std::thread;

    use super::*;

    use crate::merkle::Digest;
    use crate::storage::Storage;
    use alloy::{
        network::Ethereum,
        primitives::Address,
        providers::ProviderBuilder,
        sol_types::{SolCall, SolValue},
    };
    use cartesi_dave_contracts::dave_consensus::DaveConsensus::{self, EpochSealed};
    use cartesi_machine::{
        Machine,
        config::{
            machine::{MachineConfig, RAMConfig},
            runtime::RuntimeConfig,
        },
    };
    use cartesi_rollups_contracts::{
        i_input_box::IInputBox::{self, InputAdded},
        inputs::Inputs::EvmAdvanceCall,
    };

    use tokio::time::{Duration, sleep};

    type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
    const INPUT_PAYLOAD: &str = "Hello!";
    const INPUT_PAYLOAD2: &str = "Hello Two!";

    use super::test_utils::*;

    fn create_chain(url: &str) -> Chain {
        let url = url.parse().unwrap();
        Chain::new(
            ProviderBuilder::new()
                .connect_client(rpc_client_with_timeout(url))
                .erased(),
            Vec::new(),
        )
    }

    fn state_access() -> (tempfile::TempDir, Storage) {
        let state_dir_ = tempfile::tempdir().unwrap();
        let state_dir = state_dir_.path();

        let machine_path = state_dir.join("_my_machine_image");
        let mut machine = Machine::create(
            &MachineConfig::new_with_ram(RAMConfig {
                length: 134217728,
                backing_store: cartesi_machine::config::machine::BackingStoreConfig {
                    data_filename: "../../test/programs/linux.bin".into(),
                    ..Default::default()
                },
            }),
            &RuntimeConfig::default(),
        )
        .unwrap();
        machine.store(&machine_path).unwrap();

        let acc = Storage::initialize(
            state_dir,
            &crate::storage::Template::inspect(&machine_path).unwrap(),
            0,
            Address::ZERO,
            Address::ZERO,
            0,
            &crate::engine::TournamentGeometry::two_level(),
        )
        .unwrap();

        (state_dir_, acc)
    }

    async fn add_input(
        inputbox: &IInputBox::IInputBoxInstance<impl Provider, Ethereum>,
        application_address: Address,
        input_payload: &'static str,
        count: usize,
    ) -> Result<()> {
        for _ in 0..count {
            inputbox
                .addInput(application_address, input_payload.as_bytes().into())
                .max_fee_per_gas(10000000000)
                .send()
                .await?
                .watch()
                .await?;
        }
        Ok(())
    }

    async fn read_epochs_until_count(
        url: &str,
        consensus_address: &Address,
        count: usize,
    ) -> Result<Vec<EpochSealed>> {
        let chain = create_chain(url);
        let mut read_epochs = Vec::new();
        while read_epochs.len() != count {
            // each poll mines one block, marching the sealing block
            // toward the finalized tag
            mine_blocks(chain.provider(), 1).await?;
            // latest finalized block must be greater than 0
            let finalized = std::cmp::max(1, chain.finalized_block_number().await?);

            read_epochs = chain
                .decoded_logs::<EpochSealed>(*consensus_address, None, 1, finalized)
                .await?
                .into_iter()
                .map(|x| x.0)
                .collect();
            sleep(Duration::from_millis(20)).await;
        }

        Ok(read_epochs)
    }

    async fn read_inputs_until_count(
        url: &str,
        inputbox_address: &Address,
        application_address: &Address,
        count: usize,
    ) -> Result<Vec<InputAdded>> {
        let chain = create_chain(url);
        let mut read_inputs = Vec::new();
        while read_inputs.len() != count {
            // each poll mines one block, marching the input blocks
            // toward the finalized tag
            mine_blocks(chain.provider(), 1).await?;
            // latest finalized block must be greater than 0
            let finalized = std::cmp::max(1, chain.finalized_block_number().await?);

            read_inputs = chain
                .decoded_logs::<InputAdded>(
                    *inputbox_address,
                    Some(&application_address.into_word().into()),
                    1,
                    finalized,
                )
                .await?
                .into_iter()
                .map(|x| x.0)
                .collect();
            sleep(Duration::from_millis(20)).await;
        }

        Ok(read_inputs)
    }

    async fn read_inputs_from_db_until_count(
        provider: &impl Provider,
        storage: &mut Storage,
        epoch_number: u64,
        count: usize,
    ) -> Result<Vec<Vec<u8>>> {
        let mut read_inputs = Vec::new();
        while read_inputs.len() != count {
            // each poll mines one block so the reader thread sees the
            // input blocks reach the finalized tag
            mine_blocks(provider, 1).await?;
            read_inputs = storage.inputs(epoch_number)?;
            sleep(Duration::from_millis(20)).await;
        }

        Ok(read_inputs)
    }

    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn test_input_reader() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider().await?;
        let inputbox = IInputBox::new(address_book.input_box, &provider);

        let input_count_1 = 2;
        // Inputbox is deployed with 1 input already
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_1).await?;

        let mut read_inputs = read_inputs_until_count(
            &anvil.endpoint(),
            inputbox.address(),
            &address_book.app,
            1 + input_count_1,
        )
        .await?;
        assert_eq!(read_inputs.len(), 1 + input_count_1);

        let received_payload =
            EvmAdvanceCall::abi_decode(read_inputs.last().unwrap().input.as_ref())?;
        assert_eq!(received_payload.payload.as_ref(), INPUT_PAYLOAD.as_bytes());

        let input_count_2 = 3;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD2, input_count_2).await?;
        read_inputs = read_inputs_until_count(
            &anvil.endpoint(),
            inputbox.address(),
            &address_book.app,
            1 + input_count_1 + input_count_2,
        )
        .await?;
        assert_eq!(read_inputs.len(), 1 + input_count_1 + input_count_2);

        let received_payload =
            EvmAdvanceCall::abi_decode(read_inputs.last().unwrap().input.as_ref())?;
        assert_eq!(received_payload.payload.as_ref(), INPUT_PAYLOAD2.as_bytes());

        drop(anvil);
        Ok(())
    }

    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn test_epoch_reader() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider().await?;
        let daveconsensus = DaveConsensus::new(address_book.consensus, &provider);

        let read_epochs =
            read_epochs_until_count(&anvil.endpoint(), daveconsensus.address(), 1).await?;
        assert_eq!(read_epochs.len(), 1);
        assert_eq!(
            &read_epochs[0].initialMachineStateHash.abi_encode(),
            Digest::from_digest(&address_book.initial_hash)
                .unwrap()
                .slice()
        );

        drop(anvil);
        Ok(())
    }

    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn test_blockchain_reader() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider().await?;

        let inputbox = IInputBox::new(address_book.input_box, provider.clone());

        let (handle, mut storage) = state_access();

        let input_count_0 = 1;

        // Note that one input has been sent already
        // add inputs to epoch 1
        let input_count_1 = 2;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_1).await?;

        let shutdown = crate::sync::ShutdownSignal::default();

        let shutdown_0 = shutdown.clone();
        let reader_chain = Chain::new(provider.clone(), Vec::new());
        let r = thread::spawn(move || {
            // One block per chunk: inputs and their epoch's seal land in
            // different commits.
            let blockchain_reader = BlockchainReader::new(
                Storage::new(handle.path()).unwrap(),
                address_book,
                Duration::from_millis(20),
            )
            .with_chunk_blocks(1);

            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("`BlockchainReader` runtime build failure");

            rt.block_on(async move {
                blockchain_reader
                    .execution_loop(shutdown_0, reader_chain)
                    .await
                    .unwrap();
            })
        });

        read_inputs_from_db_until_count(&provider, &mut storage, 0, 0).await?;
        read_inputs_from_db_until_count(&provider, &mut storage, 1, input_count_0 + input_count_1)
            .await?;

        // add inputs to epoch 1
        let input_count_2 = 3;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_2).await?;
        read_inputs_from_db_until_count(
            &provider,
            &mut storage,
            1,
            input_count_0 + input_count_1 + input_count_2,
        )
        .await?;

        // add more inputs to epoch 1
        let input_count_3 = 3;
        add_input(&inputbox, address_book.app, INPUT_PAYLOAD, input_count_3).await?;
        read_inputs_from_db_until_count(
            &provider,
            &mut storage,
            1,
            input_count_0 + input_count_1 + input_count_2 + input_count_3,
        )
        .await?;

        shutdown.request();
        r.join().unwrap();
        drop(anvil);

        Ok(())
    }
}
