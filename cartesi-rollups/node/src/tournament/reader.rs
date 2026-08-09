//! The tournament reader: structure from the event fold, volatile
//! state from per-tick point reads (docs/plans/node-refactor.md,
//! workstream 5, phase 2).
//!
//! Every tick extends the durable fold through Finalized and persists
//! it before sampling Latest or rebuilding the disposable suffix.
//! Both phases use bounded range queries. The fold remains pure, fed
//! every event in global chain order, and cold start still equals tick
//! (a respawned node replays its stored prefix instead of refetching
//! hundreds of blocks of logs).
//!
//! Reorg stance, unchanged: persisted events are finalized by
//! definition; the tail past the watermark is scratch, refetched
//! every tick, and acting on tail-derived state is safe because the
//! arena sender is revert-tolerant.
//!
//! The semantic observer is the current-state authority. It joins the
//! fold with total, typed contract views pinned to the sampled head
//! hash. That hash is not required to remain canonical: the tail is
//! scratch, re-derived next tick, and a reorg can at worst make the
//! submitted mutation revert.
//!
//! Pinning's residual trade-off is that the provider must still serve
//! the sampled hash. A transient miss rejects only this observation;
//! the finalized prefix was already persisted and the next tick
//! samples again.

use anyhow::{Result, anyhow, ensure};
use std::collections::{HashMap, HashSet};

#[cfg(test)]
use alloy::primitives::U256;
use alloy::{
    primitives::{Address, B256},
    rpc::types::Log,
};

use crate::chain::{Chain, ChainHead};
use crate::storage::Storage;
use crate::tournament::{
    DisputeState, adapter,
    fold::{Fold, decode_event},
};
#[cfg(test)]
use cartesi_prt_contracts::tournament;

pub struct StateReader {
    chain: Chain,
    block_created_number: u64,
    storage: Storage,
}

impl StateReader {
    pub fn new(chain: Chain, block_created_number: u64, storage: Storage) -> Result<Self> {
        Ok(Self {
            chain,
            block_created_number,
            storage,
        })
    }

    pub async fn fetch_from_root(
        &mut self,
        root_tournament_address: Address,
    ) -> Result<DisputeState> {
        let finalized = self.chain.finalized_head().await?;
        let (finalized_fold, tail_from) = self
            .fold_finalized(root_tournament_address, finalized)
            .await?;

        let head = self.chain.latest_head().await?;
        let fold =
            Self::fold_live_tail(&self.chain, finalized_fold, tail_from, finalized, head).await?;
        let observations = adapter::observe_fold(&self.chain, &fold, head).await?;

        Ok(DisputeState {
            head,
            fold,
            observations,
        })
    }

    /// Extends and persists the finalized prefix before even sampling
    /// Latest. No volatile RPC can hold back safe durable progress.
    async fn fold_finalized(&mut self, root: Address, finalized: ChainHead) -> Result<(Fold, u64)> {
        // The persisted prefix, all tournaments in chain order; the
        // fold discovers inner tournaments as their creations replay.
        let mut persisted_logs = self.storage.tournament_events(root)?;
        normalize_logs(&mut persisted_logs)?;
        let prefix_fold = replay_logs(&Fold::new(root), &persisted_logs)?;
        let watermark = self.storage.tournament_events_watermark(root)?;
        validate_finalized_height(watermark, finalized)?;

        let tail_from = match watermark {
            Some(w) => w
                .checked_add(1)
                .ok_or_else(|| anyhow!("tournament event watermark cannot be advanced"))?,
            None => self.block_created_number,
        };

        let (finalized_fold, finalized_logs) = Self::extend_fold(
            &self.chain,
            &prefix_fold,
            tail_from,
            finalized.number,
            Some(finalized),
        )
        .await?;

        // Persist the finalized harvest before touching disposable
        // state. The watermark advances even when no relevant event
        // was emitted, keeping every later range bounded.
        if watermark.is_none_or(|value| finalized.number > value) {
            let mut harvest = Vec::new();
            for log in &finalized_logs {
                if decode_event(log)?.is_some() {
                    harvest.push(log);
                }
            }
            self.storage
                .append_tournament_events(root, finalized.number, &harvest)?;
        }

        Ok((finalized_fold, tail_from))
    }

    /// Adds the disposable number-range suffix to one finalized fold.
    async fn fold_live_tail(
        chain: &Chain,
        finalized_fold: Fold,
        tail_from: u64,
        finalized: ChainHead,
        head: ChainHead,
    ) -> Result<Fold> {
        ensure!(
            finalized.number <= head.number,
            "finalized head {} is ahead of latest head {}",
            finalized.number,
            head.number
        );
        if head.number == finalized.number {
            return Ok(finalized_fold);
        }

        let after_finalized = finalized
            .number
            .checked_add(1)
            .ok_or_else(|| anyhow!("finalized block cannot be advanced"))?;
        let scratch_from = tail_from.max(after_finalized);
        let (fold, _) =
            Self::extend_fold(chain, &finalized_fold, scratch_from, head.number, None).await?;
        Ok(fold)
    }

    /// Extends `prefix` through one inclusive number range. Address
    /// discovery grows dynamically for nested tournaments, while every
    /// address-specific batch is replayed only after global ordering.
    async fn extend_fold(
        chain: &Chain,
        prefix: &Fold,
        from: u64,
        to: u64,
        durable_boundary: Option<ChainHead>,
    ) -> Result<(Fold, Vec<Log>)> {
        if from > to {
            return Ok((prefix.clone(), Vec::new()));
        }

        let mut discovery_fold = prefix.clone();
        let mut fetched = HashSet::new();
        let mut new_logs = Vec::new();
        loop {
            let pending: Vec<Address> = discovery_fold
                .addresses()
                .into_iter()
                .filter(|address| !fetched.contains(address))
                .collect();
            if pending.is_empty() {
                break;
            }

            let mut round_logs = Vec::new();
            for address in pending {
                let logs = chain.raw_logs(address, from, to).await?;
                validate_ranged_logs(&logs, address, from, to, durable_boundary)?;
                round_logs.extend(logs);
                fetched.insert(address);
            }

            normalize_logs(&mut round_logs)?;
            new_logs.extend(round_logs);
            normalize_logs(&mut new_logs)?;
            discovery_fold = replay_logs(prefix, &new_logs)?;
        }

        Ok((discovery_fold, new_logs))
    }
}

fn validate_finalized_height(watermark: Option<u64>, finalized: ChainHead) -> Result<()> {
    if let Some(watermark) = watermark {
        ensure!(
            watermark <= finalized.number,
            "tournament event watermark {watermark} is ahead of finalized head {}",
            finalized.number
        );
    }
    Ok(())
}

fn validate_ranged_logs(
    logs: &[Log],
    address: Address,
    from: u64,
    to: u64,
    durable_boundary: Option<ChainHead>,
) -> Result<()> {
    if let Some(boundary) = durable_boundary {
        ensure!(
            boundary.number == to,
            "durable boundary {} does not end requested range [{from}, {to}]",
            boundary.number
        );
    }

    for (response_index, log) in logs.iter().enumerate() {
        ensure!(
            log.address() == address,
            "ranged log {response_index} belongs to address {}, expected {address}",
            log.address()
        );
        let block = log
            .block_number
            .ok_or_else(|| anyhow!("ranged log {response_index} has no block number"))?;
        ensure!(
            (from..=to).contains(&block),
            "requested range [{from}, {to}] returned block {block}"
        );
        if let Some(boundary) = durable_boundary
            && block == boundary.number
        {
            ensure!(
                log.block_hash == Some(boundary.hash),
                "finalized boundary log belongs to {:?}, expected {}",
                log.block_hash,
                boundary.hash
            );
        }
    }
    Ok(())
}

/// Merge address-specific RPC batches into canonical block/log order and
/// validate metadata that is meaningful only across addresses.
fn normalize_logs(logs: &mut [Log]) -> Result<()> {
    let mut block_hashes = HashMap::<u64, B256>::new();

    for (response_index, log) in logs.iter().enumerate() {
        ensure!(
            !log.removed,
            "tournament log {response_index} is marked removed"
        );
        let block = log
            .block_number
            .ok_or_else(|| anyhow!("tournament log {response_index} has no block number"))?;
        let block_hash = log
            .block_hash
            .ok_or_else(|| anyhow!("tournament log {response_index} has no block hash"))?;
        ensure!(
            log.log_index.is_some(),
            "tournament log {response_index} has no log index"
        );

        if let Some(previous) = block_hashes.insert(block, block_hash) {
            ensure!(
                previous == block_hash,
                "block {block} has conflicting hashes {previous} and {block_hash} across tournament addresses"
            );
        }
    }

    logs.sort_by_key(|log| {
        (
            log.block_number.expect("validated above"),
            log.log_index.expect("validated above"),
        )
    });
    for pair in logs.windows(2) {
        let previous_block = pair[0].block_number.expect("validated above");
        let next_block = pair[1].block_number.expect("validated above");
        if previous_block != next_block {
            continue;
        }

        let previous_log = pair[0].log_index.expect("validated above");
        let next_log = pair[1].log_index.expect("validated above");
        ensure!(
            previous_log < next_log,
            "block {previous_block} repeats global log index {previous_log}"
        );
    }
    Ok(())
}

fn replay_logs(prefix: &Fold, logs: &[Log]) -> Result<Fold> {
    let mut fold = prefix.clone();
    for log in logs {
        if let Some(event) = decode_event(log)? {
            fold.apply(&event)?;
        }
    }
    Ok(fold)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::merkle::Digest;
    use crate::storage::Storage;
    use crate::tournament::MatchID;
    use crate::tournament::fold::EventKind;
    use alloy::{
        primitives::{Bytes, Log as PrimitiveLog},
        providers::{Provider, ProviderBuilder},
        rpc::types::Block,
        rpc::{
            client::RpcClient,
            json_rpc::{RequestPacket, ResponsePacket},
        },
        sol_types::{SolCall, SolEvent},
        transports::{
            TransportError, TransportFut,
            mock::{Asserter, MockTransport},
        },
    };
    use std::{
        sync::{Arc, Mutex},
        task::{Context as TaskContext, Poll},
    };
    use tower::Service;

    #[derive(Clone, Debug)]
    struct RecordingTransport {
        inner: MockTransport,
        requests: Arc<Mutex<Vec<serde_json::Value>>>,
    }

    impl RecordingTransport {
        fn new(asserter: Asserter, requests: Arc<Mutex<Vec<serde_json::Value>>>) -> Self {
            Self {
                inner: MockTransport::new(asserter),
                requests,
            }
        }
    }

    impl Service<RequestPacket> for RecordingTransport {
        type Response = ResponsePacket;
        type Error = TransportError;
        type Future = TransportFut<'static>;

        fn poll_ready(&mut self, context: &mut TaskContext<'_>) -> Poll<Result<(), Self::Error>> {
            self.inner.poll_ready(context)
        }

        fn call(&mut self, request: RequestPacket) -> Self::Future {
            self.requests
                .lock()
                .expect("request recording mutex is not poisoned")
                .push(serde_json::to_value(&request).expect("JSON-RPC request serializes"));
            self.inner.call(request)
        }
    }

    fn digest(byte: u8) -> Digest {
        Digest::from_digest(&[byte; 32]).unwrap()
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn head(number: u64, byte: u8) -> ChainHead {
        ChainHead {
            number,
            hash: B256::repeat_byte(byte),
        }
    }

    fn block(head: ChainHead, parent_hash: B256) -> Block {
        let mut block: Block = Block::default();
        block.header.hash = head.hash;
        block.header.inner.number = head.number;
        block.header.inner.parent_hash = parent_hash;
        block
    }

    fn log_at(emitter: Address, block: ChainHead, transaction_index: u64, log_index: u64) -> Log {
        let transaction_byte =
            u8::try_from(transaction_index + 1).expect("test transaction index fits");
        Log {
            inner: PrimitiveLog::new_unchecked(emitter, Vec::new(), Bytes::new()),
            block_hash: Some(block.hash),
            block_number: Some(block.number),
            block_timestamp: None,
            transaction_hash: Some(B256::with_last_byte(transaction_byte)),
            transaction_index: Some(transaction_index),
            log_index: Some(log_index),
            removed: false,
        }
    }

    fn event_log_at<E: SolEvent>(
        emitter: Address,
        block: ChainHead,
        transaction_index: u64,
        log_index: u64,
        event: E,
    ) -> Log {
        let mut log = log_at(emitter, block, transaction_index, log_index);
        log.inner = PrimitiveLog {
            address: emitter,
            data: event.encode_log_data(),
        };
        log
    }

    fn push_call_response<C: SolCall>(asserter: &Asserter, response: &C::Return) {
        asserter.push_success(&Bytes::from(C::abi_encode_returns(response)));
    }

    fn recording_chain() -> (Chain, Asserter, Arc<Mutex<Vec<serde_json::Value>>>) {
        let asserter = Asserter::new();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let transport = RecordingTransport::new(asserter.clone(), Arc::clone(&requests));
        let provider = ProviderBuilder::new()
            .connect_client(RpcClient::new(transport, true))
            .erased();
        (Chain::new(provider, Vec::new()), asserter, requests)
    }

    fn migrated_storage() -> (tempfile::TempDir, Storage) {
        let directory = tempfile::tempdir().unwrap();
        let mut connection =
            rusqlite::Connection::open(directory.path().join("db.sqlite3")).unwrap();
        crate::storage::sql::migrations::migrate_to_latest(&mut connection).unwrap();
        drop(connection);
        let storage = Storage::new(directory.path()).unwrap();
        (directory, storage)
    }

    #[test]
    fn watermark_must_not_outrun_finalized() {
        let error = validate_finalized_height(Some(11), head(10, 0x10))
            .expect_err("watermark ahead of finalized must fail");

        assert!(error.to_string().contains("watermark 11"));
        assert!(error.to_string().contains("finalized head 10"));
    }

    #[test]
    fn address_batches_are_merged_in_global_log_order() {
        let block = head(12, 0x12);
        let root = address(1);
        let child = address(2);
        let mut logs = vec![
            log_at(root, block, 0, 2),
            log_at(root, block, 2, 4),
            log_at(child, block, 1, 3),
        ];

        normalize_logs(&mut logs).unwrap();

        assert_eq!(
            logs.iter()
                .map(|log| (log.address(), log.log_index.unwrap()))
                .collect::<Vec<_>>(),
            vec![(root, 2), (child, 3), (root, 4)]
        );
    }

    #[test]
    fn parent_and_child_batches_are_normalized_across_blocks() {
        let root = address(1);
        let child = address(2);
        let mut logs = vec![
            log_at(root, head(13, 0x13), 2, 4),
            log_at(root, head(11, 0x11), 0, 2),
            log_at(child, head(13, 0x13), 1, 3),
            log_at(child, head(12, 0x12), 0, 1),
        ];

        normalize_logs(&mut logs).unwrap();

        assert_eq!(
            logs.iter()
                .map(|log| {
                    (
                        log.block_number.unwrap(),
                        log.log_index.unwrap(),
                        log.address(),
                    )
                })
                .collect::<Vec<_>>(),
            vec![(11, 2, root), (12, 1, child), (13, 3, child), (13, 4, root),]
        );
    }

    #[test]
    fn global_order_does_not_require_transaction_metadata() {
        let block = head(12, 0x12);
        let mut logs = vec![
            log_at(address(1), block, 0, 2),
            log_at(address(2), block, 1, 3),
        ];
        for log in &mut logs {
            log.transaction_hash = None;
            log.transaction_index = None;
        }

        normalize_logs(&mut logs).unwrap();
        assert_eq!(
            logs.iter()
                .map(|log| log.log_index.unwrap())
                .collect::<Vec<_>>(),
            vec![2, 3]
        );
    }

    #[test]
    fn interleaved_parent_and_child_events_replay_as_one_global_stream() {
        let root = address(1);
        let child = address(2);
        let one = digest(10);
        let two = digest(11);
        let id_hash = MatchID {
            commitment_one: one,
            commitment_two: two,
        }
        .hash();
        let later_root = digest(12);
        let child_commitment = digest(20);

        // Model two address-specific fetch batches. The parent batch reaches
        // block 14 before the child batch, whose event belongs at block 12.
        let mut logs = vec![
            event_log_at(
                root,
                head(10, 0x10),
                0,
                0,
                tournament::Tournament::CommitmentJoined {
                    commitment: one.into(),
                    finalStateHash: digest(110).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                root,
                head(10, 0x10),
                0,
                1,
                tournament::Tournament::CommitmentJoined {
                    commitment: two.into(),
                    finalStateHash: digest(111).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                root,
                head(10, 0x10),
                0,
                2,
                tournament::Tournament::MatchCreated {
                    matchIdHash: id_hash.into(),
                    one: one.into(),
                    two: two.into(),
                    leftOfTwo: digest(30).into(),
                },
            ),
            event_log_at(
                root,
                head(11, 0x11),
                0,
                0,
                tournament::Tournament::NewInnerTournament {
                    matchIdHash: id_hash.into(),
                    childTournament: child,
                },
            ),
            event_log_at(
                root,
                head(14, 0x14),
                0,
                0,
                tournament::Tournament::CommitmentJoined {
                    commitment: later_root.into(),
                    finalStateHash: digest(112).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                child,
                head(12, 0x12),
                0,
                0,
                tournament::Tournament::CommitmentJoined {
                    commitment: child_commitment.into(),
                    finalStateHash: digest(120).into(),
                    submitter: address(9),
                },
            ),
        ];

        normalize_logs(&mut logs).unwrap();
        let fold = replay_logs(&Fold::new(root), &logs).unwrap();

        assert_eq!(
            logs.iter()
                .map(|log| (log.block_number.unwrap(), log.address()))
                .collect::<Vec<_>>(),
            vec![
                (10, root),
                (10, root),
                (10, root),
                (11, root),
                (12, child),
                (14, root),
            ]
        );
        assert_eq!(
            fold.tournament(&root).unwrap().commitments[&later_root].joined_at_block,
            14
        );
        assert_eq!(
            fold.tournament(&child).unwrap().commitments[&child_commitment].joined_at_block,
            12
        );
    }

    #[tokio::test]
    async fn ranged_extension_discovers_nested_tournaments() {
        let root = address(1);
        let child = address(2);
        let one = digest(10);
        let two = digest(11);
        let child_commitment = digest(20);
        let match_id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let (chain, asserter, requests) = recording_chain();
        let (_directory, storage) = migrated_storage();
        let reader = StateReader::new(chain, 10, storage).unwrap();

        asserter.push_success(&vec![
            event_log_at(
                root,
                head(10, 0x10),
                0,
                0,
                tournament::Tournament::CommitmentJoined {
                    commitment: one.into(),
                    finalStateHash: digest(110).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                root,
                head(10, 0x10),
                0,
                1,
                tournament::Tournament::CommitmentJoined {
                    commitment: two.into(),
                    finalStateHash: digest(111).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                root,
                head(10, 0x10),
                0,
                2,
                tournament::Tournament::MatchCreated {
                    matchIdHash: match_id.hash().into(),
                    one: one.into(),
                    two: two.into(),
                    leftOfTwo: digest(30).into(),
                },
            ),
            event_log_at(
                root,
                head(11, 0x11),
                0,
                0,
                tournament::Tournament::NewInnerTournament {
                    matchIdHash: match_id.hash().into(),
                    childTournament: child,
                },
            ),
        ]);
        asserter.push_success(&vec![event_log_at(
            child,
            head(12, 0x12),
            0,
            0,
            tournament::Tournament::CommitmentJoined {
                commitment: child_commitment.into(),
                finalStateHash: digest(120).into(),
                submitter: address(9),
            },
        )]);

        let (fold, logs) = StateReader::extend_fold(&reader.chain, &Fold::new(root), 10, 12, None)
            .await
            .unwrap();

        assert_eq!(logs.len(), 5);
        assert!(
            fold.tournament(&child)
                .unwrap()
                .commitments
                .contains_key(&child_commitment)
        );
        assert!(asserter.read_q().is_empty());

        let recorded = requests
            .lock()
            .expect("request recording mutex is not poisoned");
        let log_requests: Vec<&serde_json::Value> = recorded
            .iter()
            .filter(|request| request["method"] == "eth_getLogs")
            .collect();
        assert_eq!(log_requests.len(), 2);
        for request in log_requests {
            assert_eq!(request["params"][0]["fromBlock"], "0xa");
            assert_eq!(request["params"][0]["toBlock"], "0xc");
        }
    }

    #[test]
    fn global_log_index_collisions_across_addresses_are_rejected() {
        let block = head(12, 0x12);
        let mut logs = vec![
            log_at(address(1), block, 0, 2),
            log_at(address(2), block, 0, 2),
        ];

        let error = normalize_logs(&mut logs)
            .expect_err("one global log index cannot belong to two addresses");

        assert!(error.to_string().contains("repeats global log index 2"));
    }

    #[test]
    fn finalized_range_cannot_smuggle_a_scratch_log() {
        let root = address(1);
        let finalized = head(12, 0x12);
        let logs = [log_at(root, head(13, 0x13), 0, 1)];

        let error = validate_ranged_logs(&logs, root, 10, 12, Some(finalized))
            .expect_err("a ranged response must stay at or below finalized");

        assert!(error.to_string().contains("range [10, 12]"));
        assert!(error.to_string().contains("block 13"));
    }

    #[tokio::test]
    async fn provider_observation_uses_one_noncanonical_pinned_head() {
        let root = address(1);
        let one = digest(10);
        let two = digest(20);
        let waiting_left = digest(30);
        let match_id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let finalized = head(41, 0x41);
        let sampled = head(42, 0x42);
        let (chain, asserter, requests) = recording_chain();
        let (_directory, storage) = migrated_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        asserter.push_success(&Vec::<Log>::new());
        asserter.push_success(&Some(block(sampled, finalized.hash)));
        asserter.push_success(&vec![
            event_log_at(
                root,
                sampled,
                0,
                0,
                tournament::Tournament::CommitmentJoined {
                    commitment: one.into(),
                    finalStateHash: digest(110).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                root,
                sampled,
                0,
                1,
                tournament::Tournament::CommitmentJoined {
                    commitment: two.into(),
                    finalStateHash: digest(120).into(),
                    submitter: address(9),
                },
            ),
            event_log_at(
                root,
                sampled,
                0,
                2,
                tournament::Tournament::MatchCreated {
                    matchIdHash: match_id.hash().into(),
                    one: one.into(),
                    two: two.into(),
                    leftOfTwo: waiting_left.into(),
                },
            ),
        ]);

        push_call_response::<tournament::Tournament::tournamentDescriptorCall>(
            &asserter,
            &tournament::ITournament::TournamentDescriptor {
                initialHash: digest(9).into(),
                baseCycle: U256::ZERO,
                log2Stride: 3,
                height: 2,
                level: 0,
                kind: 0,
            },
        );
        push_call_response::<tournament::Tournament::tournamentStandingCall>(
            &asserter,
            &tournament::ITournament::TournamentStandingView {
                standing: 0,
                acceptsJoins: true,
                hasCandidate: false,
                candidate: B256::ZERO,
                finalState: B256::ZERO,
                parentCommitment: B256::ZERO,
            },
        );
        push_call_response::<tournament::Tournament::classifyMatchTimeoutCall>(
            &asserter,
            &tournament::Tournament::classifyMatchTimeoutReturn {
                actualPhase: 1,
                outcome: 0,
                deferredCharge: 0,
            },
        );
        push_call_response::<tournament::Tournament::bisectingMatchCall>(
            &asserter,
            &tournament::Tournament::bisectingMatchReturn {
                actualPhase: 1,
                value: tournament::ITournament::BisectingMatchView {
                    revealingParent: one.into(),
                    waitingLeft: waiting_left.into(),
                    waitingRight: digest(31).into(),
                    segmentStartPosition: U256::ZERO,
                    segmentStartCycle: U256::ZERO,
                    currentHeight: 2,
                    responder: 0,
                },
            },
        );

        let state = reader.fetch_from_root(root).await.unwrap();
        assert_eq!(state.head, sampled);
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(finalized.number)
        );
        assert!(reader.storage.tournament_events(root).unwrap().is_empty());
        assert!(asserter.read_q().is_empty());

        let recorded = requests
            .lock()
            .expect("request recording mutex is not poisoned")
            .clone();
        let calls: Vec<&serde_json::Value> = recorded
            .iter()
            .filter(|request| request["method"] == "eth_call")
            .collect();
        assert_eq!(calls.len(), 4);

        let expected_block = serde_json::json!({
            "blockHash": format!("{:#x}", sampled.hash),
        });
        for call in &calls {
            assert_eq!(
                call["params"][1], expected_block,
                "every semantic view must use the sampled EIP-1898 block"
            );
        }

        let call_data = |call: &&serde_json::Value| {
            call["params"][0]
                .get("input")
                .or_else(|| call["params"][0].get("data"))
                .and_then(serde_json::Value::as_str)
                .expect("eth_call carries calldata")
                .to_owned()
        };
        let timeout_selector = format!(
            "0x{}",
            hex::encode(<tournament::Tournament::classifyMatchTimeoutCall as SolCall>::SELECTOR)
        );
        let phase_selector = format!(
            "0x{}",
            hex::encode(<tournament::Tournament::bisectingMatchCall as SolCall>::SELECTOR)
        );
        assert!(
            calls
                .iter()
                .any(|call| call_data(call).starts_with(&timeout_selector))
        );
        assert!(
            calls
                .iter()
                .any(|call| call_data(call).starts_with(&phase_selector))
        );

        let block_requests: Vec<&serde_json::Value> = recorded
            .iter()
            .filter(|request| request["method"] == "eth_getBlockByNumber")
            .collect();
        assert_eq!(
            block_requests.len(),
            2,
            "only Finalized and Latest are sampled"
        );

        let log_requests: Vec<&serde_json::Value> = recorded
            .iter()
            .filter(|request| request["method"] == "eth_getLogs")
            .collect();
        assert_eq!(log_requests.len(), 2);
        assert_eq!(log_requests[0]["params"][0]["fromBlock"], "0x28");
        assert_eq!(log_requests[0]["params"][0]["toBlock"], "0x29");
        assert_eq!(log_requests[1]["params"][0]["fromBlock"], "0x2a");
        assert_eq!(log_requests[1]["params"][0]["toBlock"], "0x2a");
    }

    #[tokio::test]
    async fn latest_sampling_failure_keeps_finalized_progress() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let commitment = digest(10);
        let (chain, asserter, _) = recording_chain();
        let (_directory, storage) = migrated_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        asserter.push_success(&vec![event_log_at(
            root,
            finalized,
            0,
            0,
            tournament::Tournament::CommitmentJoined {
                commitment: commitment.into(),
                finalStateHash: digest(110).into(),
                submitter: address(9),
            },
        )]);
        asserter.push_failure_msg("latest unavailable");

        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(error.to_string().contains("latest unavailable"));
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(finalized.number)
        );
        let persisted = reader.storage.tournament_events(root).unwrap();
        assert_eq!(persisted.len(), 1);
        assert_eq!(
            decode_event(&persisted[0]).unwrap().unwrap().kind,
            EventKind::CommitmentJoined {
                root: commitment,
                final_state: digest(110),
            }
        );
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn scratch_fetch_failure_keeps_finalized_progress() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let sampled = head(42, 0x42);
        let commitment = digest(10);
        let (chain, asserter, _) = recording_chain();
        let (_directory, storage) = migrated_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        asserter.push_success(&vec![event_log_at(
            root,
            finalized,
            0,
            0,
            tournament::Tournament::CommitmentJoined {
                commitment: commitment.into(),
                finalStateHash: digest(110).into(),
                submitter: address(9),
            },
        )]);
        asserter.push_success(&Some(block(sampled, finalized.hash)));
        asserter.push_failure_msg("scratch logs unavailable");

        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(error.to_string().contains("scratch logs unavailable"));
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(finalized.number)
        );
        assert_eq!(reader.storage.tournament_events(root).unwrap().len(), 1);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn semantic_rejection_keeps_finalized_progress() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let sampled = head(42, 0x42);
        let commitment = digest(10);
        let (chain, asserter, _) = recording_chain();
        let (_directory, storage) = migrated_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        asserter.push_success(&vec![event_log_at(
            root,
            finalized,
            0,
            0,
            tournament::Tournament::CommitmentJoined {
                commitment: commitment.into(),
                finalStateHash: digest(110).into(),
                submitter: address(9),
            },
        )]);
        asserter.push_success(&Some(block(sampled, finalized.hash)));
        asserter.push_success(&Vec::<Log>::new());
        // A malformed descriptor rejects only the volatile observation.
        asserter.push_success(&Bytes::new());

        assert!(reader.fetch_from_root(root).await.is_err());
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(finalized.number)
        );
        let persisted = reader.storage.tournament_events(root).unwrap();
        assert_eq!(persisted.len(), 1);
        assert_eq!(
            decode_event(&persisted[0]).unwrap().unwrap().kind,
            EventKind::CommitmentJoined {
                root: commitment,
                final_state: digest(110),
            }
        );
        assert!(asserter.read_q().is_empty());
    }
}

/// Fold phase 2's equivalence oracle, against the chain recordings:
/// persisting a finalized prefix through the real storage path and
/// folding stored-plus-tail must reproduce the all-at-once fold
/// EXACTLY, at every block boundary of the recorded dispute. No
/// split point may change what the Hero sees; this is what makes the
/// persisted log safe to trust across restarts.
#[cfg(test)]
mod phase2_tests {
    use super::*;
    use crate::storage::Storage;
    use alloy::sol_types::SolEvent;
    use cartesi_dave_contracts::dave_consensus::DaveConsensus;

    fn recorded_logs(name: &str) -> Vec<Log> {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/chain-recordings")
            .join(name);
        let raw: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        raw["logs"]
            .as_array()
            .expect("recording carries a log array")
            .iter()
            .map(|log| serde_json::from_value(log.clone()).expect("log decodes"))
            .collect()
    }

    fn migrated_storage() -> (tempfile::TempDir, Storage) {
        let dir = tempfile::tempdir().unwrap();
        let mut conn = rusqlite::Connection::open(dir.path().join("db.sqlite3")).unwrap();
        crate::storage::sql::migrations::migrate_to_latest(&mut conn).unwrap();
        drop(conn);
        let storage = Storage::new(dir.path()).unwrap();
        (dir, storage)
    }

    #[test]
    fn stored_prefix_plus_live_tail_equals_the_whole_stream() {
        let logs = recorded_logs("echo_simple.json");
        let root = logs
            .iter()
            .filter_map(|log| DaveConsensus::EpochSealed::decode_log(&log.inner).ok())
            .find(|e| e.epochNumber == U256::from(1))
            .expect("epoch 1 is the disputed epoch")
            .tournament;

        // The whole-stream fold, discovery inline (chain order makes
        // one pass sufficient), keeping the applied raw logs.
        let mut full_fold = Fold::new(root);
        let mut dispute_logs: Vec<&Log> = Vec::new();
        for log in &logs {
            let Some(event) = decode_event(log).unwrap() else {
                continue;
            };
            if full_fold.tournament(&event.tournament).is_none() {
                continue; // another epoch's tournament or foreign contract
            }
            full_fold.apply(&event).unwrap();
            dispute_logs.push(log);
        }
        assert!(!dispute_logs.is_empty());

        let mut split_points: Vec<u64> = dispute_logs
            .iter()
            .map(|log| log.block_number.expect("recorded log has a block"))
            .collect();
        split_points.dedup();

        for split in split_points {
            let (_dir, mut storage) = migrated_storage();

            let prefix: Vec<&Log> = dispute_logs
                .iter()
                .filter(|log| log.block_number.unwrap() <= split)
                .copied()
                .collect();
            storage
                .append_tournament_events(root, split, &prefix)
                .unwrap();
            assert_eq!(
                storage.tournament_events_watermark(root).unwrap(),
                Some(split)
            );

            // The round trip: stored prefix replayed, live tail applied.
            let mut fold = Fold::new(root);
            for log in &storage.tournament_events(root).unwrap() {
                if let Some(event) = decode_event(log).unwrap() {
                    fold.apply(&event).unwrap();
                }
            }
            for log in dispute_logs
                .iter()
                .filter(|log| log.block_number.unwrap() > split)
            {
                let event = decode_event(log).unwrap().expect("dispute log decodes");
                fold.apply(&event).unwrap();
            }

            assert_eq!(fold, full_fold, "fold diverges when split at block {split}");
        }
    }
}
