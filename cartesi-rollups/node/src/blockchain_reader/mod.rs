// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use anyhow::{Context, Result};

use crate::chain::Chain;
use crate::sync::ShutdownSignal;
use alloy::{
    eips::BlockId,
    hex::ToHexExt,
    primitives::{Address, B256, U256},
    providers::Provider,
};
use cartesi_machine::types::Hash;
use log::{debug, info, trace};
use std::{fmt, iter::Peekable, time::Duration};

use crate::storage::{Epoch, Input, InputId, Storage, StorageError};
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

    /// first block that can hold the application's logs
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
        debug!("consensus created {consensus_created_block} at {consensus}");

        let initial_hash = Self::initial_hash(consensus, consensus_created_block, provider).await?;

        let app_created_block: u64 = application_contract
            .getDeploymentBlockNumber()
            .call()
            .await
            .with_context(|| format!("failed to query the deployment block of application {app}"))?
            .try_into()
            .with_context(|| format!("application {app} reports a deployment block beyond u64"))?;

        // Genesis is the earlier of the two deployments, not the InputBox's,
        // which may predate the application by millions of blocks: the
        // InputBox refuses inputs for an address without code
        // (ApplicationNotDeployed), and the consensus seals epoch 0 in its
        // constructor. Either may come first, since the application binds
        // its consensus at construction or within its deployment block.
        // Were this ever false, ingestion would meet a first input index or
        // epoch number other than 0 and refuse it.
        Ok(Self {
            app,
            consensus,
            tournament_factory,
            input_box,
            genesis_block_number: app_created_block.min(consensus_created_block),
            initial_hash,
        })
    }

    /// A new state directory's watermark, the last block ingestion treats
    /// as processed: below genesis, the first block that can hold the
    /// application's logs (epoch 0's seal included), and at most
    /// `finalized`, a finalized head sampled before this book read the
    /// deployment blocks at latest. A deployment not yet finalized at that
    /// sample can reorg only into blocks above it; a finalized one cannot
    /// move. No application or consensus log precedes the deployment, so a
    /// lower start only adds empty blocks to the first log query, and block
    /// 0 holds no transactions, so saturating is exact.
    pub fn initial_watermark(&self, finalized: u64) -> u64 {
        self.genesis_block_number.saturating_sub(1).min(finalized)
    }

    /// The initial state from epoch 0's EpochSealed, which the consensus
    /// emits in its own deployment block.
    async fn initial_hash(
        consensus: Address,
        consensus_created_block: u64,
        provider: &impl Provider,
    ) -> Result<Hash> {
        let sealed_epochs = DaveConsensus::new(consensus, provider)
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
        // looks in the wrong block, and so would ingestion from genesis.
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
        let mut failed = None;
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
                ticked = self.tick(&chain) => match ticked {
                    Ok(caught_up) => {
                        failed = None;
                        caught_up
                    }
                    Err(e) => {
                        let repeated;
                        (failed, repeated) = repeated_check(failed, &e);
                        if repeated {
                            log::error!(
                                "blockchain read failed the same log completeness check on \
                                 consecutive ticks: {e:#}; point --web3-rpc-url at a provider \
                                 that serves complete logs, and if this persists, rebuild the \
                                 state directory"
                            );
                        } else {
                            log::warn!("blockchain read failed, retrying next tick: {e:#}");
                        }
                        true
                    }
                },
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

    /// Ingests and commits the next chunk of finalized blocks, or every block
    /// up to the finalized head when the chain's totals there show nothing
    /// new; true once ingestion has reached the head. A chunk end is just
    /// another cut like the finalized head: the next chunk reseeds its
    /// numbering from storage, as the next tick does.
    pub(crate) async fn tick(&mut self, chain: &Chain) -> Result<bool> {
        let finalized = chain.finalized_block_number().await?;
        let processed = self.storage.latest_processed_block()?;
        if finalized <= processed {
            return Ok(true);
        }

        let onchain = onchain_totals(chain, self.address_book, finalized).await?;
        let stored = self.stored_totals()?;
        if stored == onchain {
            // Nothing happened since the watermark: one commit to the head,
            // without a log query, however far behind it is.
            trace!("no new input or epoch through block {finalized}");
            self.storage.insert_consensus_data(
                finalized,
                std::iter::empty(),
                std::iter::empty(),
            )?;
            return Ok(true);
        }

        let chunk_end = finalized.min(processed.saturating_add(self.chunk_blocks));
        let (inputs, epochs) = self
            .collect_events(chain, processed, chunk_end, stored, onchain)
            .await?;
        // Contiguity cannot see a log missing from the chunk's tail. The
        // totals can, but only at the head: checking an earlier chunk end
        // would need the archive state of a historical block.
        if chunk_end == finalized {
            let ingested = Totals {
                inputs: stored.inputs + inputs.len() as u64,
                last_sealed_epoch: epochs
                    .last()
                    .map(|epoch| epoch.epoch_number)
                    .or(stored.last_sealed_epoch),
            };
            ensure_complete(finalized, ingested, onchain)?;
        }

        self.storage
            .insert_consensus_data(chunk_end, inputs.iter(), epochs.iter())?;
        Ok(chunk_end == finalized)
    }

    fn stored_totals(&mut self) -> Result<Totals> {
        Ok(Totals {
            inputs: self.storage.total_input_count()?,
            last_sealed_epoch: self
                .storage
                .last_sealed_epoch()?
                .map(|epoch| epoch.epoch_number),
        })
    }

    /// The chunk's sealed epochs and numbered inputs. A total that already
    /// equals the head's cannot change within the chunk, so its log query
    /// is skipped; the inputs are numbered either way, which keeps the
    /// check of every sealed epoch's bound.
    async fn collect_events(
        &mut self,
        chain: &Chain,
        prev_block: u64,
        current_block: u64,
        stored: Totals,
        onchain: Totals,
    ) -> Result<(Vec<Input>, Vec<Epoch>)> {
        let sealed_epochs = if stored.last_sealed_epoch == onchain.last_sealed_epoch {
            Vec::new()
        } else {
            self.collect_sealed_epochs(chain, prev_block, current_block)
                .await?
        };

        let mut merged_sealed_epochs: Vec<Epoch> =
            self.storage.last_sealed_epoch()?.into_iter().collect();
        merged_sealed_epochs.extend(sealed_epochs.iter().cloned());

        let input_events = if stored.inputs == onchain.inputs {
            Vec::new()
        } else {
            self.collect_input_events(chain, prev_block, current_block)
                .await?
        };
        let inputs = self.number_inputs(&input_events, &merged_sealed_epochs)?;

        Ok((inputs, sealed_epochs))
    }

    async fn collect_sealed_epochs(
        &mut self,
        chain: &Chain,
        prev_block: u64,
        current_block: u64,
    ) -> Result<Vec<Epoch>> {
        // Errors, not panics: a panic here would stop every worker.
        chain
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
                    epoch_number: u64::try_from(e.epochNumber).with_context(|| {
                        format!("EpochSealed epoch number {} exceeds u64", e.epochNumber)
                    })?,
                    input_index_boundary: u64::try_from(e.inputIndexUpperBound).with_context(
                        || {
                            format!(
                                "EpochSealed input bound {} exceeds u64",
                                e.inputIndexUpperBound
                            )
                        },
                    )?,
                    root_tournament: e.tournament,
                    block_created_number: meta
                        .block_number
                        .context("EpochSealed log has no block number")?,
                };
                info!(
                    "epoch received: epoch_number {}, input_index_boundary {}, root_tournament {}",
                    epoch.epoch_number, epoch.input_index_boundary, epoch.root_tournament
                );
                Ok(epoch)
            })
            .collect()
    }

    async fn collect_input_events(
        &mut self,
        chain: &Chain,
        prev_block: u64,
        current_block: u64,
    ) -> Result<Vec<InputAdded>> {
        Ok(chain
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
            .collect())
    }

    fn number_inputs(
        &mut self,
        input_events: &[InputAdded],
        sealed_epochs: &[Epoch],
    ) -> Result<Vec<Input>> {
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
        for epoch in sealed_epochs {
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

/// What the application's logs add up to: its input count and its last
/// sealed epoch, read on chain at a block or from storage at the watermark
/// (no sealed epoch before epoch 0's seal is ingested).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Totals {
    inputs: u64,
    last_sealed_epoch: Option<u64>,
}

/// The application's totals at `block`, read by number: the finalized
/// head is recent, so a full node serves its state.
async fn onchain_totals(chain: &Chain, book: AddressBook, block: u64) -> Result<Totals> {
    let at = BlockId::number(block);
    let inputs = IInputBox::new(book.input_box, chain.provider())
        .getNumberOfInputs(book.app)
        .block(at)
        .call()
        .await
        .with_context(|| format!("failed to read the input count at block {block}"))?;
    let sealed = DaveConsensus::new(book.consensus, chain.provider())
        .getCurrentSealedEpoch()
        .block(at)
        .call()
        .await
        .with_context(|| format!("failed to read the sealed epoch at block {block}"))?;
    Ok(Totals {
        inputs: u64::try_from(inputs).context("the input count exceeds u64")?,
        last_sealed_epoch: Some(
            u64::try_from(sealed.epochNumber).context("the sealed epoch exceeds u64")?,
        ),
    })
}

/// Ingestion's completeness and continuity checks. One that fails again on
/// the next tick means the provider keeps omitting logs, or a chunk already
/// stored lacks one, and a retry heals neither.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LogCheck {
    /// Each InputAdded carries the next index.
    InputIndex,
    /// A sealed epoch's inputs reach its bound.
    SealedBound,
    /// The input count at the finalized head.
    HeadInputs,
    /// The last sealed epoch at the finalized head.
    HeadSealedEpoch,
    /// New inputs continue the stored ones.
    StoredInputs,
    /// New epochs continue the stored ones.
    StoredEpochs,
}

impl LogCheck {
    /// The check `error` reports failing, if any; other failures, such as
    /// transport errors, are transient.
    fn failed_by(error: &anyhow::Error) -> Option<Self> {
        if let Some(incomplete) = error.downcast_ref::<IncompleteLogs>() {
            return Some(incomplete.check);
        }
        match error.downcast_ref::<StorageError>()? {
            StorageError::InconsistentInput { .. } => Some(Self::StoredInputs),
            StorageError::InconsistentEpoch { .. } => Some(Self::StoredEpochs),
            _ => None,
        }
    }
}

/// A failed [`LogCheck`] of the reader's own, typed so the tick loop can
/// classify it.
#[derive(Debug, thiserror::Error)]
#[error("{message}")]
struct IncompleteLogs {
    check: LogCheck,
    message: String,
}

/// The check a failed tick failed, and whether the previous tick failed the
/// same one: the epoch manager's consecutive-tick rule (`repeated_reverts`).
fn repeated_check(previous: Option<LogCheck>, error: &anyhow::Error) -> (Option<LogCheck>, bool) {
    let check = LogCheck::failed_by(error);
    (check, check.is_some() && check == previous)
}

/// The tail check contiguity cannot make: once ingestion reaches the
/// finalized head, its totals must be the chain's own there. A provider
/// that truncates a log response fails the tick before anything is stored,
/// instead of leaving a gap the watermark has already passed.
fn ensure_complete(head: u64, ingested: Totals, onchain: Totals) -> Result<()> {
    anyhow::ensure!(
        ingested.inputs == onchain.inputs,
        IncompleteLogs {
            check: LogCheck::HeadInputs,
            message: format!(
                "the InputBox holds {} inputs for the application at block {head}, but \
                 ingestion reaches {}: incomplete InputAdded logs from the provider",
                onchain.inputs, ingested.inputs
            ),
        }
    );
    let show = |epoch: Option<u64>| epoch.map_or("none".to_string(), |e| e.to_string());
    anyhow::ensure!(
        ingested.last_sealed_epoch == onchain.last_sealed_epoch,
        IncompleteLogs {
            check: LogCheck::HeadSealedEpoch,
            message: format!(
                "the consensus's last sealed epoch at block {head} is {}, but ingestion \
                 reaches {}: incomplete EpochSealed logs from the provider",
                show(onchain.last_sealed_epoch),
                show(ingested.last_sealed_epoch)
            ),
        }
    );
    Ok(())
}

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
            IncompleteLogs {
                check: LogCheck::InputIndex,
                message: format!(
                    "InputAdded index {} where {} was expected: incomplete logs from the provider",
                    input_added.index, next_index
                ),
            }
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
            IncompleteLogs {
                check: LogCheck::SealedBound,
                message: format!(
                    "epoch {epoch_number} seals at input {input_index_boundary}, but only \
                     {next_index} inputs arrived: incomplete logs from the provider"
                ),
            }
        );
    }
    // input index in epoch should be reset when a new epoch starts
    *next_input_index_in_epoch = 0;

    Ok(inputs)
}

#[cfg(test)]
mod address_book_tests {
    use super::*;

    #[test]
    fn the_initial_watermark_stays_below_genesis_and_the_finalized_sample() {
        let book = AddressBook {
            app: Address::ZERO,
            consensus: Address::ZERO,
            tournament_factory: Address::ZERO,
            input_box: Address::ZERO,
            initial_hash: [0; 32],
            genesis_block_number: 1000,
        };
        assert_eq!(book.initial_watermark(5000), 999, "a finalized deployment");
        assert_eq!(book.initial_watermark(1000), 999);
        assert_eq!(book.initial_watermark(900), 900, "an unfinalized one");
        let at_zero = AddressBook {
            genesis_block_number: 0,
            ..book
        };
        assert_eq!(at_zero.initial_watermark(5000), 0);
    }
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
mod witness_tests {
    use super::*;
    use crate::chain::recording::{Requests, recording_provider};
    use alloy::{
        primitives::{Bytes, Log as PrimitiveLog},
        rpc::types::{Block, Log},
        sol_types::{SolCall, SolEvent},
        transports::mock::Asserter,
    };

    const APP: Address = Address::repeat_byte(0xaa);
    const INPUT_BOX: Address = Address::repeat_byte(0xbb);
    const CONSENSUS: Address = Address::repeat_byte(0xcc);

    struct Fixture {
        _dir: tempfile::TempDir,
        reader: BlockchainReader,
        chain: Chain,
        rpc: Asserter,
        requests: Requests,
    }

    /// A reader over a mocked provider, its storage holding epoch 0 and
    /// `inputs` inputs of epoch 1, processed through block 5.
    fn fixture(inputs: u64, chunk_blocks: u64) -> Fixture {
        let (dir, mut storage) = crate::storage::sql::test_helper::setup_storage();
        let stored: Vec<Input> = (0..inputs)
            .map(|index| Input {
                id: InputId {
                    epoch_number: 1,
                    input_index_in_epoch: index,
                },
                data: vec![],
            })
            .collect();
        storage
            .insert_consensus_data(5, stored.iter(), [&sealed(0, 0)].into_iter())
            .unwrap();
        fixture_over(dir, storage, chunk_blocks)
    }

    fn fixture_over(dir: tempfile::TempDir, storage: Storage, chunk_blocks: u64) -> Fixture {
        let (provider, rpc, requests) = recording_provider();
        let book = AddressBook {
            app: APP,
            consensus: CONSENSUS,
            tournament_factory: Address::ZERO,
            input_box: INPUT_BOX,
            initial_hash: [0; 32],
            genesis_block_number: 0,
        };
        Fixture {
            _dir: dir,
            reader: BlockchainReader::new(storage, book, Duration::ZERO)
                .with_chunk_blocks(chunk_blocks),
            chain: Chain::new(provider, Vec::new()),
            rpc,
            requests,
        }
    }

    fn sealed(epoch_number: u64, input_index_boundary: u64) -> Epoch {
        Epoch {
            epoch_number,
            input_index_boundary,
            root_tournament: Address::ZERO,
            block_created_number: 1,
        }
    }

    impl Fixture {
        /// Queues the finalized head and the chain's totals there.
        fn head(&self, finalized: u64, inputs: u64, sealed_epoch: u64) {
            let mut block: Block = Block::default();
            block.header.inner.number = finalized;
            self.rpc.push_success(&Some(block));
            self.rpc.push_success(&Bytes::from(
                IInputBox::getNumberOfInputsCall::abi_encode_returns(&U256::from(inputs)),
            ));
            self.rpc.push_success(&Bytes::from(
                DaveConsensus::getCurrentSealedEpochCall::abi_encode_returns(
                    &DaveConsensus::getCurrentSealedEpochReturn {
                        epochNumber: U256::from(sealed_epoch),
                        inputIndexLowerBound: U256::ZERO,
                        inputIndexUpperBound: U256::ZERO,
                        tournament: Address::ZERO,
                        isTournamentResultStaged: false,
                        stagingBlockNumber: U256::ZERO,
                        stagedPostEpochMachineStateHash: B256::ZERO,
                        stagedPostEpochOutputsMerkleRoot: B256::ZERO,
                    },
                ),
            ));
        }

        fn seals(&self, seals: &[(u64, u64)]) {
            let logs: Vec<Log> = seals
                .iter()
                .map(|&(epoch_number, bound)| {
                    let event = EpochSealed {
                        epochNumber: U256::from(epoch_number),
                        inputIndexLowerBound: U256::ZERO,
                        inputIndexUpperBound: U256::from(bound),
                        initialMachineStateHash: B256::ZERO,
                        outputsMerkleRoot: B256::ZERO,
                        tournament: Address::ZERO,
                    };
                    log(CONSENSUS, &event, 8, epoch_number)
                })
                .collect();
            self.rpc.push_success(&logs);
        }

        fn inputs(&self, indices: &[u64]) {
            let logs: Vec<Log> = indices
                .iter()
                .map(|&index| {
                    let event = InputAdded {
                        appContract: APP,
                        index: U256::from(index),
                        input: Bytes::new(),
                    };
                    log(INPUT_BOX, &event, 8, index)
                })
                .collect();
            self.rpc.push_success(&logs);
        }

        /// The addresses of the log queries sent, in order.
        fn log_queries(&self) -> Vec<String> {
            self.requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .map(|request| request["params"][0]["address"].as_str().unwrap().to_owned())
                .collect()
        }

        fn stored(&mut self) -> (u64, Totals) {
            let processed = self.reader.storage.latest_processed_block().unwrap();
            (processed, self.reader.stored_totals().unwrap())
        }
    }

    fn log(address: Address, event: &impl SolEvent, block: u64, index: u64) -> Log {
        Log {
            inner: PrimitiveLog {
                address,
                data: event.encode_log_data(),
            },
            block_hash: Some(B256::repeat_byte(0x11)),
            block_number: Some(block),
            block_timestamp: None,
            transaction_hash: Some(B256::repeat_byte(0x22)),
            transaction_index: Some(index),
            log_index: Some(index),
            removed: false,
        }
    }

    fn address(address: Address) -> String {
        format!("{address:#x}")
    }

    fn totals(inputs: u64, last_sealed_epoch: u64) -> Totals {
        Totals {
            inputs,
            last_sealed_epoch: Some(last_sealed_epoch),
        }
    }

    #[tokio::test]
    async fn a_quiet_range_commits_to_the_head_without_logs() {
        let mut f = fixture(2, 1);
        f.head(100_000, 2, 0);

        assert!(f.reader.tick(&f.chain).await.unwrap());
        assert!(f.log_queries().is_empty());
        assert_eq!(f.stored(), (100_000, totals(2, 0)));
        assert!(f.rpc.read_q().is_empty());

        // the totals are read at the head, by number
        let requests = f.requests.lock().unwrap();
        let calls: Vec<_> = requests
            .iter()
            .filter(|request| request["method"] == "eth_call")
            .collect();
        assert_eq!(calls.len(), 2);
        for call in calls {
            assert_eq!(call["params"][1], serde_json::json!("0x186a0"));
        }
    }

    /// The new seal bounds the stored inputs without any input log, which
    /// keeps the bound check sound when the input query is skipped.
    #[tokio::test]
    async fn a_matching_input_count_skips_the_input_query() {
        let mut f = fixture(2, 1_000);
        f.head(10, 2, 1);
        f.seals(&[(1, 2)]);

        assert!(f.reader.tick(&f.chain).await.unwrap());
        assert_eq!(f.log_queries(), [address(CONSENSUS)]);
        assert_eq!(f.stored(), (10, totals(2, 1)));
    }

    /// The numbering still runs without input logs, so a seal whose bound
    /// is not the stored count is refused.
    #[tokio::test]
    async fn a_skipped_input_query_still_checks_the_seal_bound() {
        let mut f = fixture(2, 1_000);
        f.head(10, 2, 1);
        f.seals(&[(1, 3)]);

        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert!(
            error.to_string().contains("seals at input 3"),
            "unexpected error: {error:#}"
        );
        assert_eq!(LogCheck::failed_by(&error), Some(LogCheck::SealedBound));
        assert_eq!(f.stored(), (5, totals(2, 0)), "nothing is committed");
    }

    /// A fresh directory holds no sealed epoch, so even a chain that shows
    /// nothing past epoch 0 is scanned for epoch 0's seal.
    #[tokio::test]
    async fn a_fresh_directory_scans_for_epoch_zero() {
        let (dir, storage) = crate::storage::sql::test_helper::setup_storage();
        let mut f = fixture_over(dir, storage, 1_000);
        f.head(10, 0, 0);
        f.seals(&[(0, 0)]);

        assert!(f.reader.tick(&f.chain).await.unwrap());
        assert_eq!(f.log_queries(), [address(CONSENSUS)]);
        assert_eq!(f.stored(), (10, totals(0, 0)));
    }

    #[tokio::test]
    async fn a_matching_sealed_epoch_skips_the_seal_query() {
        let mut f = fixture(0, 1_000);
        f.head(10, 2, 0);
        f.inputs(&[0, 1]);

        assert!(f.reader.tick(&f.chain).await.unwrap());
        assert_eq!(f.log_queries(), [address(INPUT_BOX)]);
        assert_eq!(f.stored(), (10, totals(2, 0)));
        assert_eq!(f.reader.storage.input_count(1).unwrap(), 2);
    }

    #[tokio::test]
    async fn a_truncated_tail_is_refused_at_the_head() {
        let mut f = fixture(0, 1_000);
        f.head(10, 2, 0);
        f.inputs(&[0]);

        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert!(
            error.to_string().contains("incomplete InputAdded logs"),
            "unexpected error: {error:#}"
        );
        assert_eq!(LogCheck::failed_by(&error), Some(LogCheck::HeadInputs));
        assert_eq!(f.stored(), (5, totals(0, 0)), "nothing is committed");
    }

    #[tokio::test]
    async fn a_missing_seal_is_refused_at_the_head() {
        let mut f = fixture(0, 1_000);
        f.head(10, 0, 1);
        f.seals(&[]);

        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert!(
            error.to_string().contains("incomplete EpochSealed logs"),
            "unexpected error: {error:#}"
        );
        assert_eq!(LogCheck::failed_by(&error), Some(LogCheck::HeadSealedEpoch));
        assert_eq!(f.stored(), (5, totals(0, 0)), "nothing is committed");
    }

    /// Before the first seal is ingested nothing matches, so a fresh
    /// directory always scans, and a missing epoch 0 is refused.
    #[test]
    fn no_stored_epoch_matches_the_chain() {
        let fresh = Totals {
            inputs: 0,
            last_sealed_epoch: None,
        };
        assert_ne!(fresh, totals(0, 0));
        let error = ensure_complete(10, fresh, totals(0, 0)).unwrap_err();
        assert!(error.to_string().contains("ingestion reaches none"));
        ensure_complete(10, totals(3, 2), totals(3, 2)).unwrap();
    }

    #[tokio::test]
    async fn a_reordered_response_is_ingested_in_chain_order() {
        let mut f = fixture(0, 1_000);
        f.head(10, 3, 0);
        f.inputs(&[2, 0, 1]);

        assert!(f.reader.tick(&f.chain).await.unwrap());
        assert_eq!(f.stored(), (10, totals(3, 0)));
    }

    /// The contracts cannot emit it, so it is an inconsistent response: an
    /// error that retries, not a panic that stops the node.
    #[tokio::test]
    async fn an_oversized_epoch_number_is_an_error() {
        let mut f = fixture(0, 1_000);
        f.head(10, 0, 1);
        let event = EpochSealed {
            epochNumber: U256::MAX,
            inputIndexLowerBound: U256::ZERO,
            inputIndexUpperBound: U256::ZERO,
            initialMachineStateHash: B256::ZERO,
            outputsMerkleRoot: B256::ZERO,
            tournament: Address::ZERO,
        };
        f.rpc.push_success(&vec![log(CONSENSUS, &event, 8, 0)]);

        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert!(
            format!("{error:#}").contains("exceeds u64"),
            "unexpected error: {error:#}"
        );
        assert_eq!(LogCheck::failed_by(&error), None);
        assert_eq!(f.stored(), (5, totals(0, 0)), "nothing is committed");
    }

    /// An input index gap, and logs that do not continue the stored rows (a
    /// seal or input dropped at an earlier chunk's tail), fail typed checks;
    /// a transport failure fails none.
    #[tokio::test]
    async fn completeness_and_continuity_failures_are_typed() {
        let mut f = fixture(0, 1_000);
        f.head(10, 2, 0);
        f.inputs(&[1]);
        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert_eq!(LogCheck::failed_by(&error), Some(LogCheck::InputIndex));

        // Epoch 1's seal was dropped: epoch 2's follows epoch 0's.
        let mut f = fixture(2, 1_000);
        f.head(10, 2, 2);
        f.seals(&[(2, 2)]);
        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert_eq!(LogCheck::failed_by(&error), Some(LogCheck::StoredEpochs));

        // So input 2, stored as epoch 1's third, is really epoch 2's first.
        let mut f = fixture(3, 1_000);
        f.head(10, 4, 2);
        f.seals(&[(2, 4)]);
        f.inputs(&[3]);
        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert_eq!(LogCheck::failed_by(&error), Some(LogCheck::StoredInputs));

        let mut f = fixture(0, 1_000);
        f.rpc.push_failure_msg("connection refused");
        let error = f.reader.tick(&f.chain).await.unwrap_err();
        assert_eq!(LogCheck::failed_by(&error), None);
    }

    #[test]
    fn a_failed_check_escalates_only_when_it_repeats_on_the_next_tick() {
        let incomplete = |check| {
            anyhow::Error::new(IncompleteLogs {
                check,
                message: String::new(),
            })
        };
        let transient = anyhow::anyhow!("connection refused");

        // The first failure is a warning only; the same one next tick is not.
        let (first, repeated) = repeated_check(None, &incomplete(LogCheck::HeadInputs));
        assert!(!repeated);
        let (second, repeated) = repeated_check(first, &incomplete(LogCheck::HeadInputs));
        assert!(repeated);
        // Another check, or a transient failure between, starts over.
        assert!(!repeated_check(second, &incomplete(LogCheck::InputIndex)).1);
        let (cleared, repeated) = repeated_check(second, &transient);
        assert!(!repeated);
        assert!(!repeated_check(cleared, &incomplete(LogCheck::HeadInputs)).1);
        assert!(!repeated_check(cleared, &transient).1);
    }

    /// A chunk that ends before the head cannot be checked against it: it
    /// commits on contiguity alone, and catch-up goes on.
    #[tokio::test]
    async fn a_chunk_before_the_head_commits_on_contiguity() {
        let mut f = fixture(0, 10);
        f.head(1_000, 5, 0);
        f.inputs(&[0, 1]);

        assert!(!f.reader.tick(&f.chain).await.unwrap());
        assert_eq!(f.stored(), (15, totals(2, 0)));
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

    /// Genesis is the application's deployment block, which holds epoch
    /// 0's seal, and a directory seeded right below it, the highest seed,
    /// for a finalized deployment, ingests that seal.
    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn ingestion_starts_at_the_application_deployment() -> Result<()> {
        let (anvil, provider, address_book) = spawn_anvil_and_provider().await?;
        let chain = Chain::new(provider.clone(), Vec::new());
        // finality trails latest by two blocks
        mine_blocks(&provider, 3).await?;
        let watermark = address_book.initial_watermark(chain.finalized_block_number().await?);
        assert_eq!(watermark, address_book.genesis_block_number - 1);

        let latest = chain.latest_block_number().await?;
        let seals = chain
            .decoded_logs::<EpochSealed>(address_book.consensus, None, 0, latest)
            .await?;
        assert_eq!(
            seals[0].1.block_number,
            Some(address_book.genesis_block_number)
        );
        let input_box_block: u64 = IInputBox::new(address_book.input_box, &provider)
            .getDeploymentBlockNumber()
            .call()
            .await?
            .try_into()?;
        assert!(input_box_block < address_book.genesis_block_number);

        let dir = tempfile::tempdir()?;
        let template = dir.path().join("_template");
        crate::storage::sql::test_helper::store_template(&template, |_| {});
        let storage = Storage::initialize(
            dir.path(),
            &crate::storage::Template::inspect(&template)?,
            watermark,
            address_book.app,
            address_book.consensus,
            0,
            &crate::engine::TournamentGeometry::two_level(),
        )?;
        let mut reader = BlockchainReader::new(storage, address_book, Duration::ZERO);
        while !reader.tick(&chain).await? {}

        let sealed = reader.storage.last_sealed_epoch()?.map(|e| e.epoch_number);
        assert_eq!(sealed, Some(0));
        assert_eq!(reader.storage.total_input_count()?, 1);

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
