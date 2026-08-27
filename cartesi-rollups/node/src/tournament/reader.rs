// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! A fused recursive reader for the event-derived dispute tree.
//!
//! Finalized state is the sole durable prefix. It is extended, validated, and
//! persisted before Latest is sampled. Latest is then rebuilt from a clone of
//! that prefix and discarded by the caller after the tick.

use std::collections::{HashMap, HashSet};

use alloy::{
    primitives::{Address, B256},
    rpc::types::Log,
    sol_types::SolEvent,
};
use anyhow::{Context, Result, anyhow, bail, ensure};
use async_recursion::async_recursion;
use cartesi_prt_contracts::tournament as bindings;

use crate::{
    chain::{Chain, ChainHead},
    merkle::Digest,
    storage::Storage,
    tournament::{
        MatchID,
        dispute::{
            Dispute, Event, EventKind, MatchDeletionReason, MatchStatus, Tournament,
            WinnerCommitment,
        },
        observer,
    },
};

#[derive(Clone, Debug)]
struct Solid {
    root: Address,
    head: ChainHead,
    dispute: Dispute,
}

pub struct StateReader {
    chain: Chain,
    block_created_number: u64,
    storage: Storage,
    solid: Option<Solid>,
}

impl StateReader {
    pub fn new(chain: Chain, block_created_number: u64, storage: Storage) -> Result<Self> {
        Ok(Self {
            chain,
            block_created_number,
            storage,
            solid: None,
        })
    }

    pub const fn chain(&self) -> &Chain {
        &self.chain
    }

    /// The in-memory finalized prefix used for join payloads and decisions.
    pub fn solid(&self) -> Option<(ChainHead, &Dispute)> {
        self.solid
            .as_ref()
            .map(|solid| (solid.head, &solid.dispute))
    }

    /// Returns one disposable Latest observation after durably advancing Solid.
    pub async fn fetch_from_root(&mut self, root: Address) -> Result<(ChainHead, Dispute)> {
        let finalized = self.chain.finalized_head().await?;
        self.advance_solid(root, finalized).await?;

        let latest = self.chain.latest_head().await?;
        let solid = self.solid.as_ref().expect("advancing Solid initializes it");
        ensure!(
            latest.number >= solid.head.number,
            "latest head {} is behind finalized Solid {}",
            latest.number,
            solid.head.number
        );
        if latest.number == solid.head.number {
            ensure!(
                latest.hash == solid.head.hash,
                "latest and finalized disagree at block {}: {} != {}",
                latest.number,
                latest.hash,
                solid.head.hash
            );
            return Ok((latest, solid.dispute.clone()));
        }

        let from = solid
            .head
            .number
            .checked_add(1)
            .ok_or_else(|| anyhow!("finalized Solid block cannot be advanced"))?;
        let phase = ReadPhase::try_new(from, latest.number, latest, None)?;
        let mut validation = HarvestValidation::new(phase);
        let loaded = extend_tournament(
            &self.chain,
            solid.dispute.clone().into_root(),
            &mut validation,
        )
        .await?;
        let dispute = Dispute::from_root(loaded.tournament)?;
        Ok((latest, dispute))
    }

    async fn advance_solid(&mut self, root: Address, finalized: ChainHead) -> Result<()> {
        let Some(solid) = self.solid.as_ref() else {
            let initialized = self.initialize_solid(root, finalized).await?;
            self.solid = Some(initialized);
            return Ok(());
        };

        ensure!(
            solid.root == root,
            "StateReader is bound to root {}, not {root}",
            solid.root
        );
        ensure!(
            finalized.number >= solid.head.number,
            "finalized head {} is behind Solid {}",
            finalized.number,
            solid.head.number
        );
        if finalized.number == solid.head.number {
            ensure!(
                finalized.hash == solid.head.hash,
                "finalized block {} changed hash from {} to {}",
                finalized.number,
                solid.head.hash,
                finalized.hash
            );
            return Ok(());
        }

        let base = solid.dispute.clone();
        let from = solid
            .head
            .number
            .checked_add(1)
            .ok_or_else(|| anyhow!("finalized Solid block cannot be advanced"))?;
        let phase = ReadPhase::try_new(from, finalized.number, finalized, Some(finalized))?;
        let mut validation = HarvestValidation::new(phase);
        let mut loaded = extend_tournament(&self.chain, base.into_root(), &mut validation).await?;
        sort_logs(&mut loaded.recognized_logs);
        let dispute = Dispute::from_root(loaded.tournament)?;
        self.persist(root, finalized.number, &loaded.recognized_logs)?;
        self.solid = Some(Solid {
            root,
            head: finalized,
            dispute,
        });
        Ok(())
    }

    async fn initialize_solid(&mut self, root: Address, finalized: ChainHead) -> Result<Solid> {
        let watermark = self.storage.tournament_events_watermark(root)?;
        if let Some(watermark) = watermark {
            ensure!(
                watermark <= finalized.number,
                "tournament event watermark {watermark} is ahead of finalized head {}",
                finalized.number
            );
        }
        let stored_logs = self.storage.tournament_events(root)?;
        ensure!(
            watermark.is_some() || stored_logs.is_empty(),
            "stored tournament events exist without a finalized watermark"
        );

        let root_descriptor = observer::read_descriptor(&self.chain, root, finalized).await?;
        let mut dispute = Dispute::try_new(root_descriptor)?;
        if let Some(watermark) = watermark {
            let boundary = (watermark == finalized.number).then_some(finalized);
            let phase =
                ReadPhase::try_new(self.block_created_number, watermark, finalized, boundary)?;
            dispute = reconstruct_stored(&self.chain, dispute, stored_logs, phase).await?;
        }

        let from = watermark
            .map(|block| {
                block
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("tournament event watermark cannot be advanced"))
            })
            .transpose()?
            .unwrap_or(self.block_created_number)
            .max(self.block_created_number);

        let mut recognized_logs = Vec::new();
        if from <= finalized.number {
            let phase = ReadPhase::try_new(from, finalized.number, finalized, Some(finalized))?;
            let mut validation = HarvestValidation::new(phase);
            let loaded =
                extend_tournament(&self.chain, dispute.into_root(), &mut validation).await?;
            dispute = Dispute::from_root(loaded.tournament)?;
            recognized_logs = loaded.recognized_logs;
            sort_logs(&mut recognized_logs);
        }

        if watermark != Some(finalized.number) {
            self.persist(root, finalized.number, &recognized_logs)?;
        }
        Ok(Solid {
            root,
            head: finalized,
            dispute,
        })
    }

    fn persist(&mut self, root: Address, finalized: u64, logs: &[Log]) -> Result<()> {
        let references = logs.iter().collect::<Vec<_>>();
        self.storage
            .append_tournament_events(root, finalized, &references)?;
        Ok(())
    }
}

#[derive(Debug)]
struct LoadedTournament {
    tournament: Tournament,
    recognized_logs: Vec<Log>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ReadPhase {
    from: u64,
    to: u64,
    head: ChainHead,
    durable_boundary: Option<ChainHead>,
}

impl ReadPhase {
    fn try_new(
        from: u64,
        to: u64,
        head: ChainHead,
        durable_boundary: Option<ChainHead>,
    ) -> Result<Self> {
        if let Some(boundary) = durable_boundary {
            ensure!(
                boundary.number == to,
                "durable boundary {} does not end requested range [{from}, {to}]",
                boundary.number
            );
            ensure!(
                boundary == head,
                "durable boundary must be the phase's pinned head"
            );
        }
        Ok(Self {
            from,
            to,
            head,
            durable_boundary,
        })
    }
}

#[async_recursion]
async fn extend_tournament(
    chain: &Chain,
    tournament: Tournament,
    validation: &mut HarvestValidation,
) -> Result<LoadedTournament> {
    let phase = validation.phase;
    if phase.from > phase.to {
        return Ok(LoadedTournament {
            tournament,
            recognized_logs: Vec::new(),
        });
    }

    let address = tournament.address();
    let frozen_children = tournament
        .matches()
        .filter(|match_| {
            matches!(
                match_.status(),
                MatchStatus::Resolved { child: Some(_), .. }
            )
        })
        .map(|match_| match_.id_hash())
        .collect::<HashSet<_>>();
    let logs = chain.raw_logs(address, phase.from, phase.to).await?;
    let (mut tournament, mut recognized_logs) =
        fold_local_logs(chain, tournament, logs, validation).await?;

    let children = tournament.take_historical_children();
    for (match_id_hash, child) in children {
        if frozen_children.contains(&match_id_hash) {
            let displaced = tournament.restore_child(match_id_hash, child)?;
            drop(displaced);
            continue;
        }
        let mut loaded = extend_tournament(chain, *child, validation).await?;
        let displaced = tournament.restore_child(match_id_hash, Box::new(loaded.tournament))?;
        drop(displaced);
        recognized_logs.append(&mut loaded.recognized_logs);
    }
    tournament.validate()?;
    Ok(LoadedTournament {
        tournament,
        recognized_logs,
    })
}

async fn reconstruct_stored(
    chain: &Chain,
    dispute: Dispute,
    logs: Vec<Log>,
    phase: ReadPhase,
) -> Result<Dispute> {
    let mut streams = HashMap::<Address, Vec<Log>>::new();
    for log in logs {
        streams.entry(log.address()).or_default().push(log);
    }
    let mut validation = HarvestValidation::new(phase);
    let root =
        replay_stored_tournament(chain, dispute.into_root(), &mut streams, &mut validation).await?;

    if !streams.is_empty() {
        let mut addresses = streams.keys().copied().collect::<Vec<_>>();
        addresses.sort_unstable();
        bail!(
            "stored tournament event streams are not reachable from the trusted root: {addresses:?}"
        );
    }
    Dispute::from_root(root).map_err(Into::into)
}

#[async_recursion]
async fn replay_stored_tournament(
    chain: &Chain,
    tournament: Tournament,
    streams: &mut HashMap<Address, Vec<Log>>,
    validation: &mut HarvestValidation,
) -> Result<Tournament> {
    let address = tournament.address();
    let logs = streams.remove(&address).unwrap_or_default();
    let (mut tournament, _) = fold_local_logs(chain, tournament, logs, validation).await?;

    let children = tournament.take_historical_children();
    for (match_id_hash, child) in children {
        let child = replay_stored_tournament(chain, *child, streams, validation).await?;
        let displaced = tournament.restore_child(match_id_hash, Box::new(child))?;
        drop(displaced);
    }
    tournament.validate()?;
    Ok(tournament)
}

async fn fold_local_logs(
    chain: &Chain,
    mut tournament: Tournament,
    mut logs: Vec<Log>,
    validation: &mut HarvestValidation,
) -> Result<(Tournament, Vec<Log>)> {
    let address = tournament.address();
    for log in &logs {
        validation.observe(log, address)?;
    }
    sort_logs(&mut logs);

    let mut structural = Vec::<(u64, Event)>::new();
    let mut recognized_logs = Vec::new();
    for log in logs {
        let block = log.block_number.expect("harvest metadata was validated");
        match decode_log(chain, &log, validation.phase.head).await? {
            DecodedLog::Structural { event, new_child } => {
                if let Some(child) = new_child {
                    validation.register_child(
                        child,
                        LogPosition {
                            block,
                            index: log.log_index.expect("harvest metadata was validated"),
                        },
                    )?;
                }
                structural.push((block, event));
                recognized_logs.push(log);
            }
            DecodedLog::IgnoredAccounting => {}
        }
    }

    let mut start = 0;
    while start < structural.len() {
        let block = structural[start].0;
        let mut end = start + 1;
        while end < structural.len() && structural[end].0 == block {
            end += 1;
        }
        let events = structural[start..end]
            .iter()
            .map(|(_, event)| event.clone())
            .collect::<Vec<_>>();
        tournament = tournament.apply_block(events).with_context(|| {
            format!(
                "events for tournament {address} at block {block} do not fold under the current ABI; deploy contracts and node across a coordinated version boundary"
            )
        })?;
        start = end;
    }

    Ok((tournament, recognized_logs))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
struct LogPosition {
    block: u64,
    index: u64,
}

struct HarvestValidation {
    phase: ReadPhase,
    block_hashes: HashMap<u64, B256>,
    positions: HashSet<LogPosition>,
    first_by_address: HashMap<Address, LogPosition>,
    discoveries: HashMap<Address, LogPosition>,
}

impl HarvestValidation {
    fn new(phase: ReadPhase) -> Self {
        Self {
            phase,
            block_hashes: HashMap::new(),
            positions: HashSet::new(),
            first_by_address: HashMap::new(),
            discoveries: HashMap::new(),
        }
    }

    fn observe(&mut self, log: &Log, expected_address: Address) -> Result<()> {
        let ReadPhase {
            from,
            to,
            durable_boundary,
            ..
        } = self.phase;
        ensure!(
            log.address() == expected_address,
            "ranged log belongs to address {}, expected {expected_address}",
            log.address()
        );
        ensure!(!log.removed, "tournament log is marked removed");
        let block = log
            .block_number
            .ok_or_else(|| anyhow!("tournament log has no block number"))?;
        ensure!(
            from <= block && block <= to,
            "requested range [{from}, {to}] returned block {block}"
        );
        let block_hash = log
            .block_hash
            .ok_or_else(|| anyhow!("tournament log at block {block} has no block hash"))?;
        ensure!(
            block_hash != B256::ZERO,
            "tournament log at block {block} has a zero block hash"
        );
        let index = log
            .log_index
            .ok_or_else(|| anyhow!("tournament log at block {block} has no log index"))?;
        let position = LogPosition { block, index };
        ensure!(
            self.positions.insert(position),
            "global tournament log position ({block}, {index}) was returned twice"
        );

        if let Some(previous) = self.block_hashes.insert(block, block_hash) {
            ensure!(
                previous == block_hash,
                "block {block} has conflicting hashes {previous} and {block_hash} across tournament addresses"
            );
        }
        if let Some(boundary) = durable_boundary
            && block == boundary.number
        {
            ensure!(
                block_hash == boundary.hash,
                "finalized boundary log belongs to {block_hash}, expected {}",
                boundary.hash
            );
        }
        if let Some(discovered_at) = self.discoveries.get(&expected_address) {
            ensure!(
                position > *discovered_at,
                "child tournament {expected_address} emitted at {position:?} before its discovery at {discovered_at:?}"
            );
        }
        self.first_by_address
            .entry(expected_address)
            .and_modify(|first| *first = (*first).min(position))
            .or_insert(position);
        Ok(())
    }

    fn register_child(&mut self, child: Address, discovered_at: LogPosition) -> Result<()> {
        ensure!(
            self.discoveries.insert(child, discovered_at).is_none(),
            "child tournament {child} was discovered more than once in one harvest"
        );
        if let Some(first) = self.first_by_address.get(&child) {
            ensure!(
                *first > discovered_at,
                "child tournament {child} emitted at {first:?} before its discovery at {discovered_at:?}"
            );
        }
        Ok(())
    }
}

fn sort_logs(logs: &mut [Log]) {
    logs.sort_by_key(|log| {
        (
            log.block_number.expect("harvest metadata was validated"),
            log.log_index.expect("harvest metadata was validated"),
        )
    });
}

#[derive(Debug)]
enum DecodedLog {
    Structural {
        event: Event,
        new_child: Option<Address>,
    },
    IgnoredAccounting,
}

async fn decode_log(chain: &Chain, log: &Log, head: ChainHead) -> Result<DecodedLog> {
    let tournament = log.address();
    let topic = log
        .inner
        .topics()
        .first()
        .copied()
        .ok_or_else(|| anyhow!("tournament {tournament} emitted a log without a topic"))?;

    let (kind, new_child) = if topic == bindings::Tournament::CommitmentJoined::SIGNATURE_HASH {
        let event = bindings::Tournament::CommitmentJoined::decode_log(&log.inner)
            .context("malformed CommitmentJoined event")?;
        (
            EventKind::CommitmentJoined {
                root: event.commitment.into(),
                final_state: event.finalStateHash.into(),
                submitter: event.submitter,
            },
            None,
        )
    } else if topic == bindings::Tournament::MatchCreated::SIGNATURE_HASH {
        let event = bindings::Tournament::MatchCreated::decode_log(&log.inner)
            .context("malformed MatchCreated event")?;
        let id = MatchID {
            commitment_one: event.one.into(),
            commitment_two: event.two.into(),
        };
        let emitted: Digest = event.matchIdHash.into();
        ensure!(
            emitted == id.hash(),
            "MatchCreated hash {emitted} disagrees with commitments ({}, {})",
            id.commitment_one,
            id.commitment_two
        );
        (
            EventKind::MatchCreated {
                id,
                eliminable_at: event.eliminableAt,
            },
            None,
        )
    } else if topic == bindings::Tournament::MatchAdvanced::SIGNATURE_HASH {
        let event = bindings::Tournament::MatchAdvanced::decode_log(&log.inner)
            .context("malformed MatchAdvanced event")?;
        (
            EventKind::MatchAdvanced {
                match_id_hash: event.matchIdHash.into(),
                eliminable_at: event.eliminableAt,
            },
            None,
        )
    } else if topic == bindings::Tournament::LeafMatchSealed::SIGNATURE_HASH {
        let event = bindings::Tournament::LeafMatchSealed::decode_log(&log.inner)
            .context("malformed LeafMatchSealed event")?;
        (
            EventKind::LeafMatchSealed {
                match_id_hash: event.matchIdHash.into(),
                eliminable_at: event.eliminableAt,
            },
            None,
        )
    } else if topic == bindings::Tournament::NewInnerTournament::SIGNATURE_HASH {
        let event = bindings::Tournament::NewInnerTournament::decode_log(&log.inner)
            .context("malformed NewInnerTournament event")?;
        let child = event.childTournament;
        ensure!(
            child != Address::ZERO,
            "NewInnerTournament names the zero address"
        );
        let descriptor = observer::read_descriptor(chain, child, head).await?;
        (
            EventKind::NewInnerTournament {
                match_id_hash: event.matchIdHash.into(),
                child: descriptor,
            },
            Some(child),
        )
    } else if topic == bindings::Tournament::MatchDeleted::SIGNATURE_HASH {
        let event = bindings::Tournament::MatchDeleted::decode_log(&log.inner)
            .context("malformed MatchDeleted event")?;
        let id = MatchID {
            commitment_one: event.one.into(),
            commitment_two: event.two.into(),
        };
        let emitted: Digest = event.matchIdHash.into();
        ensure!(
            emitted == id.hash(),
            "MatchDeleted hash {emitted} disagrees with commitments ({}, {})",
            id.commitment_one,
            id.commitment_two
        );
        let reason = match event.reason {
            0 => MatchDeletionReason::Step,
            1 => MatchDeletionReason::Timeout,
            2 => MatchDeletionReason::ChildTournament,
            other => bail!("unknown match deletion reason {other}"),
        };
        let winner = match event.winnerCommitment {
            0 => WinnerCommitment::Neither,
            1 => WinnerCommitment::One,
            2 => WinnerCommitment::Two,
            other => bail!("unknown winner commitment {other}"),
        };
        (
            EventKind::MatchDeleted {
                match_id_hash: emitted,
                reason,
                winner,
            },
            None,
        )
    } else if topic == bindings::Tournament::PartialBondRefund::SIGNATURE_HASH {
        bindings::Tournament::PartialBondRefund::decode_log(&log.inner)
            .context("malformed PartialBondRefund event")?;
        return Ok(DecodedLog::IgnoredAccounting);
    } else if topic == bindings::Tournament::BondRecovered::SIGNATURE_HASH {
        bindings::Tournament::BondRecovered::decode_log(&log.inner)
            .context("malformed BondRecovered event")?;
        return Ok(DecodedLog::IgnoredAccounting);
    } else {
        bail!(
            "tournament {tournament} emitted unknown event topic {topic}; current tournament event ABI required, deploy contracts and node across a coordinated version boundary"
        );
    };

    Ok(DecodedLog::Structural {
        event: Event { tournament, kind },
        new_child,
    })
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{Arc, Mutex},
        task::{Context as TaskContext, Poll},
    };

    use alloy::{
        primitives::{Bytes, Log as PrimitiveLog, U256, keccak256},
        providers::{Provider, ProviderBuilder},
        rpc::{
            client::RpcClient,
            json_rpc::{RequestPacket, ResponsePacket},
            types::Block,
        },
        sol_types::{SolCall, SolEvent},
        transports::{
            TransportError, TransportFut,
            mock::{Asserter, MockTransport},
        },
    };
    use tower::Service;

    use super::*;
    use crate::tournament::{
        dispute::{CommitmentPosition, MatchStatus},
        domain::{TournamentDescriptor, TournamentKind},
    };

    #[derive(Clone, Debug)]
    struct RecordingTransport {
        inner: MockTransport,
        requests: Arc<Mutex<Vec<serde_json::Value>>>,
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
        Digest::from([byte; 32])
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

    fn descriptor(address: Address, level: u64, kind: TournamentKind) -> TournamentDescriptor {
        TournamentDescriptor::try_new(address, level, kind, digest(9), U256::ZERO, 0, 1).unwrap()
    }

    fn descriptor_response(
        level: u64,
        kind: TournamentKind,
    ) -> bindings::ITournament::TournamentDescriptor {
        bindings::ITournament::TournamentDescriptor {
            initialHash: digest(9).into(),
            baseCycle: U256::ZERO,
            log2Stride: 0,
            height: 1,
            level,
            kind: match kind {
                TournamentKind::Leaf => 0,
                TournamentKind::NonLeaf => 1,
            },
        }
    }

    fn log_at(emitter: Address, at: ChainHead, index: u64) -> Log {
        Log {
            inner: PrimitiveLog::new_unchecked(emitter, Vec::new(), Bytes::new()),
            block_hash: Some(at.hash),
            block_number: Some(at.number),
            block_timestamp: None,
            transaction_hash: None,
            transaction_index: None,
            log_index: Some(index),
            removed: false,
        }
    }

    fn event_log_at<E: SolEvent>(emitter: Address, at: ChainHead, index: u64, event: E) -> Log {
        let mut log = log_at(emitter, at, index);
        log.inner = PrimitiveLog {
            address: emitter,
            data: event.encode_log_data(),
        };
        log
    }

    fn join_log(emitter: Address, at: ChainHead, index: u64, root: Digest) -> Log {
        event_log_at(
            emitter,
            at,
            index,
            bindings::Tournament::CommitmentJoined {
                commitment: root.into(),
                finalStateHash: digest(root.data()[0].wrapping_add(100)).into(),
                submitter: address(root.data()[0]),
            },
        )
    }

    fn match_created_log(
        emitter: Address,
        at: ChainHead,
        index: u64,
        id: MatchID,
        eliminable_at: u64,
    ) -> Log {
        event_log_at(
            emitter,
            at,
            index,
            bindings::Tournament::MatchCreated {
                matchIdHash: id.hash().into(),
                one: id.commitment_one.into(),
                two: id.commitment_two.into(),
                leftOfTwo: digest(90).into(),
                eliminableAt: eliminable_at,
            },
        )
    }

    fn new_inner_log(
        emitter: Address,
        at: ChainHead,
        index: u64,
        match_id_hash: Digest,
        child: Address,
    ) -> Log {
        event_log_at(
            emitter,
            at,
            index,
            bindings::Tournament::NewInnerTournament {
                matchIdHash: match_id_hash.into(),
                childTournament: child,
            },
        )
    }

    fn match_deleted_log(
        emitter: Address,
        at: ChainHead,
        index: u64,
        id: MatchID,
        reason: MatchDeletionReason,
        winner: WinnerCommitment,
    ) -> Log {
        event_log_at(
            emitter,
            at,
            index,
            bindings::Tournament::MatchDeleted {
                matchIdHash: id.hash().into(),
                one: id.commitment_one.into(),
                two: id.commitment_two.into(),
                reason: match reason {
                    MatchDeletionReason::Step => 0,
                    MatchDeletionReason::Timeout => 1,
                    MatchDeletionReason::ChildTournament => 2,
                },
                winnerCommitment: match winner {
                    WinnerCommitment::Neither => 0,
                    WinnerCommitment::One => 1,
                    WinnerCommitment::Two => 2,
                },
            },
        )
    }

    struct ActiveRecursiveDispute {
        root: Address,
        child: Address,
        parent_match: MatchID,
        child_match: MatchID,
        dispute: Dispute,
    }

    fn active_recursive_dispute() -> ActiveRecursiveDispute {
        let root = address(1);
        let child = address(2);
        let one = digest(10);
        let two = digest(20);
        let child_one = digest(30);
        let child_two = digest(40);
        let parent_match = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let child_match = MatchID {
            commitment_one: child_one,
            commitment_two: child_two,
        };
        let event = |tournament, kind| Event { tournament, kind };
        let join = |tournament, root, final_state, submitter| {
            event(
                tournament,
                EventKind::CommitmentJoined {
                    root,
                    final_state,
                    submitter,
                },
            )
        };
        let dispute = Dispute::try_new(descriptor(root, 0, TournamentKind::NonLeaf))
            .unwrap()
            .apply_block([join(root, one, digest(110), address(10))])
            .unwrap()
            .apply_block([
                join(root, two, digest(120), address(20)),
                event(
                    root,
                    EventKind::MatchCreated {
                        id: parent_match,
                        eliminable_at: 20,
                    },
                ),
            ])
            .unwrap()
            .apply_block([event(
                root,
                EventKind::NewInnerTournament {
                    match_id_hash: parent_match.hash(),
                    child: descriptor(child, 1, TournamentKind::Leaf),
                },
            )])
            .unwrap()
            .apply_block([join(child, child_one, digest(130), address(30))])
            .unwrap()
            .apply_block([
                join(child, child_two, digest(140), address(40)),
                event(
                    child,
                    EventKind::MatchCreated {
                        id: child_match,
                        eliminable_at: 20,
                    },
                ),
            ])
            .unwrap();

        ActiveRecursiveDispute {
            root,
            child,
            parent_match,
            child_match,
            dispute,
        }
    }

    fn push_call_response<C: SolCall>(asserter: &Asserter, response: &C::Return) {
        asserter.push_success(&Bytes::from(C::abi_encode_returns(response)));
    }

    fn recording_chain() -> (Chain, Asserter, Arc<Mutex<Vec<serde_json::Value>>>) {
        let asserter = Asserter::new();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let transport = RecordingTransport {
            inner: MockTransport::new(asserter.clone()),
            requests: Arc::clone(&requests),
        };
        let provider = ProviderBuilder::new()
            .connect_client(RpcClient::new(transport, true))
            .erased();
        (Chain::new(provider, Vec::new()), asserter, requests)
    }

    fn initialized_storage() -> (tempfile::TempDir, Storage) {
        let directory = tempfile::tempdir().unwrap();
        let connection = rusqlite::Connection::open(directory.path().join("db.sqlite3")).unwrap();
        crate::storage::sql::schema::initialize(&connection).unwrap();
        drop(connection);
        let storage = Storage::new(directory.path()).unwrap();
        (directory, storage)
    }

    #[test]
    fn harvest_validation_is_global_but_needs_no_transaction_metadata() {
        let range_head = head(12, 0x12);
        let root = address(1);
        let child = address(2);
        let phase = ReadPhase::try_new(10, 12, range_head, Some(range_head)).unwrap();
        let mut validation = HarvestValidation::new(phase);
        validation
            .observe(&log_at(root, range_head, 2), root)
            .unwrap();
        validation
            .observe(&log_at(child, range_head, 3), child)
            .unwrap();

        let duplicate = validation
            .observe(&log_at(child, range_head, 2), child)
            .unwrap_err();
        assert!(duplicate.to_string().contains("returned twice"));

        let phase = ReadPhase::try_new(10, 12, range_head, None).unwrap();
        let mut conflicting = HarvestValidation::new(phase);
        conflicting
            .observe(&log_at(root, range_head, 1), root)
            .unwrap();
        let error = conflicting
            .observe(&log_at(child, head(12, 0x99), 2), child)
            .unwrap_err();
        assert!(error.to_string().contains("conflicting hashes"));
    }

    #[tokio::test]
    async fn decoder_is_strict_and_preserves_submitter() {
        let root = address(1);
        let at = head(10, 0x10);
        let (chain, asserter, _) = recording_chain();
        let joined = join_log(root, at, 0, digest(10));
        let DecodedLog::Structural { event, .. } = decode_log(&chain, &joined, at).await.unwrap()
        else {
            panic!("join was ignored");
        };
        assert_eq!(
            event.kind,
            EventKind::CommitmentJoined {
                root: digest(10),
                final_state: digest(110),
                submitter: address(10),
            }
        );

        let id = MatchID {
            commitment_one: digest(10),
            commitment_two: digest(20),
        };
        let mut bad_hash = match_created_log(root, at, 1, id, 30);
        bad_hash.inner = PrimitiveLog {
            address: root,
            data: bindings::Tournament::MatchCreated {
                matchIdHash: digest(99).into(),
                one: id.commitment_one.into(),
                two: id.commitment_two.into(),
                leftOfTwo: digest(90).into(),
                eliminableAt: 30,
            }
            .encode_log_data(),
        };
        assert!(decode_log(&chain, &bad_hash, at).await.is_err());

        let mut unknown = log_at(root, at, 2);
        unknown.inner =
            PrimitiveLog::new_unchecked(root, vec![B256::repeat_byte(0xaa)], Bytes::new());
        assert!(decode_log(&chain, &unknown, at).await.is_err());

        let refund = event_log_at(
            root,
            at,
            3,
            bindings::Tournament::PartialBondRefund {
                recipient: address(2),
                value: U256::from(3),
                success: true,
            },
        );
        assert!(matches!(
            decode_log(&chain, &refund, at).await.unwrap(),
            DecodedLog::IgnoredAccounting
        ));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn pre_deadline_event_abi_fails_as_a_coordinated_boundary() {
        let root = address(1);
        let at = head(10, 0x10);
        let (chain, asserter, _) = recording_chain();
        let mut legacy = log_at(root, at, 0);
        legacy.inner = PrimitiveLog::new_unchecked(
            root,
            vec![keccak256("MatchCreated(bytes32,bytes32,bytes32,bytes32)")],
            Bytes::new(),
        );

        let error = decode_log(&chain, &legacy, at).await.unwrap_err();
        assert!(error.to_string().contains("coordinated version boundary"));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn recursive_extension_discovers_and_fills_a_child() {
        let root = address(1);
        let child = address(2);
        let at = head(12, 0x12);
        let discovery_block = head(11, 0x11);
        let one = digest(10);
        let two = digest(20);
        let child_commitment = digest(30);
        let id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let (chain, asserter, requests) = recording_chain();
        asserter.push_success(&vec![
            join_log(root, head(10, 0x10), 0, one),
            join_log(root, head(10, 0x10), 1, two),
            match_created_log(root, head(10, 0x10), 2, id, 30),
            new_inner_log(root, discovery_block, 3, id.hash(), child),
        ]);
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(1, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![join_log(child, discovery_block, 4, child_commitment)]);

        let root = Tournament::new(descriptor(root, 0, TournamentKind::NonLeaf));
        let phase = ReadPhase::try_new(10, 12, at, None).unwrap();
        let mut validation = HarvestValidation::new(phase);
        let loaded = extend_tournament(&chain, root, &mut validation)
            .await
            .unwrap();
        let dispute = Dispute::from_root(loaded.tournament).unwrap();
        let child_tournament = dispute.tournament(&child).unwrap();
        assert!(child_tournament.commitment(&child_commitment).is_some());
        assert_eq!(loaded.recognized_logs.len(), 5);
        assert!(matches!(
            dispute
                .root()
                .match_by_id_hash(&id.hash())
                .unwrap()
                .status(),
            MatchStatus::Inner { .. }
        ));
        assert!(asserter.read_q().is_empty());

        let recorded = requests.lock().unwrap();
        assert_eq!(
            recorded
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count(),
            2
        );
        let descriptor_call = recorded
            .iter()
            .find(|request| request["method"] == "eth_call")
            .unwrap();
        assert_eq!(
            descriptor_call["params"][1],
            serde_json::json!({ "blockHash": format!("{:#x}", at.hash) })
        );
    }

    #[tokio::test]
    async fn same_block_child_resolution_completes_parent_first_loading() {
        let fixture = active_recursive_dispute();
        let at = head(20, 0x20);
        let (chain, asserter, requests) = recording_chain();

        // The parent is fetched first even though its deletion is later in the
        // block than the child's final deletion.
        asserter.push_success(&vec![match_deleted_log(
            fixture.root,
            at,
            8,
            fixture.parent_match,
            MatchDeletionReason::ChildTournament,
            WinnerCommitment::One,
        )]);
        asserter.push_success(&vec![match_deleted_log(
            fixture.child,
            at,
            7,
            fixture.child_match,
            MatchDeletionReason::Timeout,
            WinnerCommitment::One,
        )]);

        let phase = ReadPhase::try_new(at.number, at.number, at, None).unwrap();
        let mut validation = HarvestValidation::new(phase);
        let loaded = extend_tournament(&chain, fixture.dispute.into_root(), &mut validation)
            .await
            .unwrap();
        let dispute = Dispute::from_root(loaded.tournament).unwrap();
        let parent = dispute
            .root()
            .match_by_id_hash(&fixture.parent_match.hash())
            .unwrap();
        let MatchStatus::Resolved {
            child: Some(child), ..
        } = parent.status()
        else {
            panic!("parent match did not retain its resolved child");
        };
        assert!(matches!(
            child
                .match_by_id_hash(&fixture.child_match.hash())
                .unwrap()
                .status(),
            MatchStatus::Resolved { .. }
        ));
        assert_eq!(loaded.recognized_logs.len(), 2);
        assert!(asserter.read_q().is_empty());
        assert_eq!(
            requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count(),
            2,
            "the newly resolved child must receive its final range fetch"
        );
    }

    #[tokio::test]
    async fn newly_resolved_child_is_persisted_once_then_frozen_and_cold_replayed() {
        let fixture = active_recursive_dispute();
        let root = fixture.root;
        let child = fixture.child;
        let parent_match = fixture.parent_match;
        let child_match = fixture.child_match;
        let created = head(10, 0x10);
        let resolved = head(20, 0x20);
        let after_resolution = head(21, 0x21);
        let (chain, asserter, requests) = recording_chain();
        let (_directory, storage) = initialized_storage();
        let state_dir = storage.state_dir().to_path_buf();
        let mut reader = StateReader::new(chain.clone(), created.number, storage).unwrap();
        let log_request_count = || {
            requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count()
        };

        asserter.push_success(&Some(block(created, B256::repeat_byte(9))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::NonLeaf),
        );
        asserter.push_success(&vec![
            join_log(root, created, 0, parent_match.commitment_one),
            join_log(root, created, 1, parent_match.commitment_two),
            match_created_log(root, created, 2, parent_match, 30),
            new_inner_log(root, created, 3, parent_match.hash(), child),
        ]);
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(1, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![
            join_log(child, created, 4, child_match.commitment_one),
            join_log(child, created, 5, child_match.commitment_two),
            match_created_log(child, created, 6, child_match, 30),
        ]);
        asserter.push_success(&Some(block(created, B256::repeat_byte(9))));
        reader.fetch_from_root(root).await.unwrap();
        assert_eq!(log_request_count(), 2);

        asserter.push_success(&Some(block(resolved, created.hash)));
        asserter.push_success(&vec![match_deleted_log(
            root,
            resolved,
            8,
            parent_match,
            MatchDeletionReason::ChildTournament,
            WinnerCommitment::One,
        )]);
        asserter.push_success(&vec![match_deleted_log(
            child,
            resolved,
            7,
            child_match,
            MatchDeletionReason::Timeout,
            WinnerCommitment::One,
        )]);
        asserter.push_success(&Some(block(resolved, created.hash)));
        reader.fetch_from_root(root).await.unwrap();
        assert_eq!(log_request_count(), 4);

        let persisted = reader.storage.tournament_events(root).unwrap();
        assert_eq!(persisted.len(), 9);
        assert_eq!(
            persisted
                .iter()
                .filter(|log| {
                    log.address() == child && log.block_number == Some(resolved.number)
                })
                .count(),
            1,
            "the child's final structural event is persisted exactly once"
        );

        asserter.push_success(&Some(block(after_resolution, resolved.hash)));
        asserter.push_success(&Vec::<Log>::new());
        asserter.push_success(&Some(block(after_resolution, resolved.hash)));
        reader.fetch_from_root(root).await.unwrap();
        assert_eq!(
            log_request_count(),
            5,
            "the range after resolution extends only the root stream"
        );
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(after_resolution.number)
        );
        assert_eq!(reader.storage.tournament_events(root).unwrap().len(), 9);

        let cold_storage = Storage::new(&state_dir).unwrap();
        let mut cold_reader = StateReader::new(chain, created.number, cold_storage).unwrap();
        asserter.push_success(&Some(block(after_resolution, resolved.hash)));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::NonLeaf),
        );
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(1, TournamentKind::Leaf),
        );
        asserter.push_success(&Some(block(after_resolution, resolved.hash)));
        let (_, cold) = cold_reader.fetch_from_root(root).await.unwrap();
        assert_eq!(
            log_request_count(),
            5,
            "cold replay at the watermark does not refetch any stream"
        );
        assert_eq!(cold.reachable_tournaments().len(), 1);
        assert_eq!(cold.historical_tournaments().len(), 2);
        let parent = cold.root().match_by_id_hash(&parent_match.hash()).unwrap();
        let MatchStatus::Resolved {
            child: Some(child), ..
        } = parent.status()
        else {
            panic!("cold replay lost the resolved historical child");
        };
        assert!(matches!(
            child
                .match_by_id_hash(&child_match.hash())
                .unwrap()
                .status(),
            MatchStatus::Resolved { .. }
        ));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn resolved_historical_children_are_not_refetched() {
        let root = address(1);
        let child = address(2);
        let one = digest(10);
        let two = digest(20);
        let child_one = digest(30);
        let child_two = digest(40);
        let parent_match = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let child_match = MatchID {
            commitment_one: child_one,
            commitment_two: child_two,
        };
        let event = |tournament, kind| Event { tournament, kind };
        let join = |tournament, root, final_state, submitter| {
            event(
                tournament,
                EventKind::CommitmentJoined {
                    root,
                    final_state,
                    submitter,
                },
            )
        };
        let dispute = Dispute::try_new(descriptor(root, 0, TournamentKind::NonLeaf))
            .unwrap()
            .apply_block([join(root, one, digest(110), address(10))])
            .unwrap()
            .apply_block([
                join(root, two, digest(120), address(20)),
                event(
                    root,
                    EventKind::MatchCreated {
                        id: parent_match,
                        eliminable_at: 20,
                    },
                ),
            ])
            .unwrap()
            .apply_block([event(
                root,
                EventKind::NewInnerTournament {
                    match_id_hash: parent_match.hash(),
                    child: descriptor(child, 1, TournamentKind::Leaf),
                },
            )])
            .unwrap()
            .apply_block([join(child, child_one, digest(130), address(30))])
            .unwrap()
            .apply_block([
                join(child, child_two, digest(140), address(40)),
                event(
                    child,
                    EventKind::MatchCreated {
                        id: child_match,
                        eliminable_at: 20,
                    },
                ),
            ])
            .unwrap()
            .apply_block([event(
                child,
                EventKind::MatchDeleted {
                    match_id_hash: child_match.hash(),
                    reason: MatchDeletionReason::Timeout,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap()
            .apply_block([event(
                root,
                EventKind::MatchDeleted {
                    match_id_hash: parent_match.hash(),
                    reason: MatchDeletionReason::ChildTournament,
                    winner: WinnerCommitment::One,
                },
            )])
            .unwrap();

        let at = head(21, 0x21);
        let (chain, asserter, requests) = recording_chain();
        asserter.push_success(&Vec::<Log>::new());
        let phase = ReadPhase::try_new(21, 21, at, None).unwrap();
        let mut validation = HarvestValidation::new(phase);
        let loaded = extend_tournament(&chain, dispute.into_root(), &mut validation)
            .await
            .unwrap();
        let dispute = Dispute::from_root(loaded.tournament).unwrap();

        assert_eq!(dispute.historical_tournaments().len(), 2);
        assert!(asserter.read_q().is_empty());
        let requests = requests.lock().unwrap();
        assert_eq!(
            requests
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count(),
            1,
            "only the still-active root stream is extended"
        );
    }

    #[tokio::test]
    async fn finalized_progress_survives_latest_failure() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let commitment = digest(10);
        let (chain, asserter, _) = recording_chain();
        let (_directory, storage) = initialized_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![join_log(root, finalized, 0, commitment)]);
        asserter.push_failure_msg("latest unavailable");

        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(error.to_string().contains("latest unavailable"));
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(finalized.number)
        );
        assert_eq!(reader.storage.tournament_events(root).unwrap().len(), 1);
        let (head, solid) = reader.solid().unwrap();
        assert_eq!(head, finalized);
        assert!(matches!(
            solid.root().position(&commitment),
            CommitmentPosition::Candidate { .. }
        ));
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn different_latest_tails_are_rebuilt_from_the_same_solid() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let first_latest = head(42, 0x42);
        let second_latest = head(43, 0x43);
        let one = digest(10);
        let two = digest(20);
        let three = digest(30);
        let first_id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let second_id = MatchID {
            commitment_one: one,
            commitment_two: three,
        };
        let first_tail = vec![
            join_log(root, first_latest, 0, two),
            match_created_log(root, first_latest, 1, first_id, 50),
        ];
        let second_tail = vec![
            join_log(root, second_latest, 0, three),
            match_created_log(root, second_latest, 1, second_id, 51),
        ];
        let (chain, asserter, requests) = recording_chain();
        let (_directory, storage) = initialized_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![join_log(root, finalized, 0, one)]);
        asserter.push_success(&Some(block(first_latest, finalized.hash)));
        asserter.push_success(&first_tail);

        let (observed_head, first) = reader.fetch_from_root(root).await.unwrap();
        assert_eq!(observed_head, first_latest);
        assert!(first.root().match_by_id_hash(&first_id.hash()).is_some());
        assert!(first.root().commitment(&two).is_some());
        assert!(reader.solid().unwrap().1.root().match_for(&one).is_none());

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        asserter.push_success(&Some(block(second_latest, first_latest.hash)));
        asserter.push_success(&second_tail);
        let (observed_head, second) = reader.fetch_from_root(root).await.unwrap();
        assert_eq!(observed_head, second_latest);
        assert_ne!(first, second);
        assert!(second.root().match_by_id_hash(&second_id.hash()).is_some());
        assert!(second.root().match_by_id_hash(&first_id.hash()).is_none());
        assert!(second.root().commitment(&two).is_none());
        assert_eq!(reader.storage.tournament_events(root).unwrap().len(), 1);
        assert_eq!(reader.solid().unwrap().0, finalized);
        assert!(asserter.read_q().is_empty());

        let requests = requests.lock().unwrap();
        assert_eq!(
            requests
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count(),
            3,
            "one finalized harvest and two independent Latest harvests"
        );
    }

    #[tokio::test]
    async fn cached_solid_advances_only_over_the_new_finalized_range() {
        let root = address(1);
        let first_finalized = head(41, 0x41);
        let second_finalized = head(43, 0x43);
        let one = digest(10);
        let two = digest(20);
        let id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let (chain, asserter, requests) = recording_chain();
        let (_directory, storage) = initialized_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(first_finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![join_log(root, first_finalized, 0, one)]);
        asserter.push_success(&Some(block(first_finalized, B256::repeat_byte(0x40))));
        reader.fetch_from_root(root).await.unwrap();

        asserter.push_success(&Some(block(second_finalized, B256::repeat_byte(0x42))));
        asserter.push_success(&vec![
            join_log(root, second_finalized, 0, two),
            match_created_log(root, second_finalized, 1, id, 60),
        ]);
        asserter.push_success(&Some(block(second_finalized, B256::repeat_byte(0x42))));
        let (observed_head, dispute) = reader.fetch_from_root(root).await.unwrap();

        assert_eq!(observed_head, second_finalized);
        assert_eq!(reader.solid().unwrap().0, second_finalized);
        assert!(dispute.root().match_by_id_hash(&id.hash()).is_some());
        assert!(
            reader
                .solid()
                .unwrap()
                .1
                .root()
                .match_by_id_hash(&id.hash())
                .is_some()
        );
        assert_eq!(
            reader.storage.tournament_events_watermark(root).unwrap(),
            Some(second_finalized.number)
        );
        let persisted = reader.storage.tournament_events(root).unwrap();
        assert_eq!(persisted.len(), 3);
        assert_eq!(
            persisted
                .iter()
                .map(|log| log.block_number.unwrap())
                .collect::<Vec<_>>(),
            vec![41, 43, 43]
        );
        assert!(asserter.read_q().is_empty());

        let requests = requests.lock().unwrap();
        let log_requests = requests
            .iter()
            .filter(|request| request["method"] == "eth_getLogs")
            .collect::<Vec<_>>();
        assert_eq!(log_requests.len(), 2);
        assert_eq!(
            log_requests[0]["params"][0]["fromBlock"],
            serde_json::json!("0x28")
        );
        assert_eq!(
            log_requests[0]["params"][0]["toBlock"],
            serde_json::json!("0x29")
        );
        assert_eq!(
            log_requests[1]["params"][0]["fromBlock"],
            serde_json::json!("0x2a")
        );
        assert_eq!(
            log_requests[1]["params"][0]["toBlock"],
            serde_json::json!("0x2b")
        );
    }

    #[tokio::test]
    async fn cold_start_reconstructs_a_recursive_dispute() {
        let root = address(1);
        let child = address(2);
        let joined_at = head(10, 0x10);
        let finalized = head(11, 0x11);
        let one = digest(10);
        let two = digest(20);
        let child_commitment = digest(30);
        let id = MatchID {
            commitment_one: one,
            commitment_two: two,
        };
        let root_logs = [
            join_log(root, joined_at, 0, one),
            join_log(root, joined_at, 1, two),
            match_created_log(root, joined_at, 2, id, 30),
            new_inner_log(root, finalized, 3, id.hash(), child),
        ];
        let child_log = join_log(child, finalized, 4, child_commitment);

        let (chain, asserter, requests) = recording_chain();
        let (_directory, mut storage) = initialized_storage();
        let stored = root_logs.iter().chain([&child_log]).collect::<Vec<_>>();
        storage
            .append_tournament_events(root, finalized.number, &stored)
            .unwrap();
        let mut reader = StateReader::new(chain, 10, storage).unwrap();

        asserter.push_success(&Some(block(finalized, joined_at.hash)));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::NonLeaf),
        );
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(1, TournamentKind::Leaf),
        );
        asserter.push_success(&Some(block(finalized, joined_at.hash)));

        let (observed_head, dispute) = reader.fetch_from_root(root).await.unwrap();
        assert_eq!(observed_head, finalized);
        assert_eq!(reader.solid().unwrap().0, finalized);
        assert!(
            dispute
                .tournament(&child)
                .unwrap()
                .commitment(&child_commitment)
                .is_some()
        );
        assert!(matches!(
            dispute
                .root()
                .match_by_id_hash(&id.hash())
                .unwrap()
                .status(),
            MatchStatus::Inner { .. }
        ));
        assert!(asserter.read_q().is_empty());

        let requests = requests.lock().unwrap();
        assert_eq!(
            requests
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count(),
            0
        );
        assert_eq!(
            requests
                .iter()
                .filter(|request| request["method"] == "eth_call")
                .count(),
            2
        );
    }

    #[tokio::test]
    async fn cold_start_rejects_unreachable_stored_streams() {
        let root = address(1);
        let orphan = address(2);
        let finalized = head(10, 0x10);
        let (chain, asserter, _) = recording_chain();
        let (_directory, mut storage) = initialized_storage();
        let root_log = join_log(root, finalized, 0, digest(10));
        let orphan_log = join_log(orphan, finalized, 1, digest(20));
        storage
            .append_tournament_events(root, finalized.number, &[&root_log, &orphan_log])
            .unwrap();
        let mut reader = StateReader::new(chain, 10, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(9))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(
            error
                .to_string()
                .contains("not reachable from the trusted root")
        );
        assert!(reader.solid().is_none());
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn finalized_same_height_hash_change_is_fatal() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let (chain, asserter, _) = recording_chain();
        let (_directory, storage) = initialized_storage();
        let mut reader = StateReader::new(chain, 40, storage).unwrap();

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&Vec::<Log>::new());
        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        reader.fetch_from_root(root).await.unwrap();

        let contradictory = head(finalized.number, 0x99);
        asserter.push_success(&Some(block(contradictory, B256::repeat_byte(0x40))));
        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(error.to_string().contains("changed hash"));
        assert_eq!(reader.solid().unwrap().0, finalized);
        assert!(asserter.read_q().is_empty());
    }
}
