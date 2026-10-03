// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! A fused recursive reader for the event-derived dispute tree.
//!
//! Finalized state is an in-memory prefix, extended before Latest is sampled.
//! Latest is then rebuilt from a clone of that prefix and discarded by the
//! caller after the tick. Nothing is persisted: a new reader refolds the
//! finalized history from the root's creation block, so a restart runs the cold
//! path and cannot inherit a bad prefix from disk.

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
    tournament::{
        MatchID,
        dispute::{
            Dispute, DisputeError, EventKind, MatchDeletionReason, Tournament, WinnerCommitment,
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
    solid: Option<Solid>,
}

impl StateReader {
    pub const fn new(chain: Chain, block_created_number: u64) -> Self {
        Self {
            chain,
            block_created_number,
            solid: None,
        }
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

    /// Drops Solid when `error` holds a pinned phase read that contradicts a
    /// match's folded status, so the next fetch refolds from the root's
    /// creation block as a restart would. A missed finalized seal or
    /// delegation still folds, and Foam extends Solid only past `F`, so
    /// otherwise every tick would fail the same way. A lagging or mixed Foam
    /// tail costs one refold; a persistent cause, one refold per tick.
    pub fn forget_contradicted_solid(&mut self, error: &anyhow::Error) {
        let contradicted = error.chain().any(|cause| {
            matches!(
                cause.downcast_ref::<observer::ObserverError>(),
                Some(observer::ObserverError::EventPhaseMismatch { .. })
            )
        });
        if contradicted {
            self.solid = None;
        }
    }

    /// Returns one disposable Latest observation after advancing Solid.
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
        let mut validation = HarvestValidation::new(ReadPhase { from, head: latest });
        let tournament = extend_tournament(
            &self.chain,
            solid.dispute.clone().into_root(),
            &mut validation,
        )
        .await?;
        Ok((latest, Dispute::from_root(tournament)))
    }

    /// Without a Solid, the fold starts at the root's creation block.
    async fn advance_solid(&mut self, root: Address, finalized: ChainHead) -> Result<()> {
        let (base, from) = match self.solid.as_ref() {
            None => {
                let descriptor = observer::read_descriptor(&self.chain, root, finalized).await?;
                (Dispute::try_new(descriptor)?, self.block_created_number)
            }
            Some(solid) => {
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
                let from = solid
                    .head
                    .number
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("finalized Solid block cannot be advanced"))?;
                (solid.dispute.clone(), from)
            }
        };

        let mut validation = HarvestValidation::new(ReadPhase {
            from,
            head: finalized,
        });
        let tournament =
            match extend_tournament(&self.chain, base.into_root(), &mut validation).await {
                Ok(tournament) => tournament,
                Err(error) => {
                    // A finalized event that does not fold means the prefix
                    // missed a log, and extending it fails the same way every
                    // tick. Drop it, so the next tick refolds from the root's
                    // creation block as a restart would. Other failures
                    // (transport, harvest, decode) keep it and retry the range,
                    // so a struggling provider is not handed full refolds.
                    if error.downcast_ref::<DisputeError>().is_some() {
                        self.solid = None;
                    }
                    return Err(error);
                }
            };
        self.solid = Some(Solid {
            root,
            head: finalized,
            dispute: Dispute::from_root(tournament),
        });
        Ok(())
    }
}

/// One harvest over `[from, head.number]`, read against the head sampled
/// for it: finalized for Solid, latest for Foam. A log at the head's height
/// must carry its hash, which catches a range served from another fork
/// whenever the head itself holds a tournament log. Ancestry below the head
/// is not proven: a mixed tail is a stale observation, which contract
/// mutators revalidate and the next tick rebuilds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ReadPhase {
    from: u64,
    head: ChainHead,
}

#[async_recursion]
async fn extend_tournament(
    chain: &Chain,
    tournament: Tournament,
    validation: &mut HarvestValidation,
) -> Result<Tournament> {
    let phase = validation.phase;
    if phase.from > phase.head.number {
        return Ok(tournament);
    }

    let address = tournament.address();
    let logs = chain
        .raw_logs(address, phase.from, phase.head.number)
        .await?;
    let mut tournament = fold_local_logs(chain, tournament, logs, validation).await?;

    // A child resolved within the range was dropped with its match, so its
    // stream is never fetched.
    for (match_id_hash, child) in tournament.take_children() {
        let child = extend_tournament(chain, *child, validation).await?;
        drop(tournament.restore_child(match_id_hash, Box::new(child)));
    }
    Ok(tournament)
}

async fn fold_local_logs(
    chain: &Chain,
    mut tournament: Tournament,
    mut logs: Vec<Log>,
    validation: &mut HarvestValidation,
) -> Result<Tournament> {
    let address = tournament.address();
    for log in &logs {
        validation.observe(log, address)?;
    }
    sort_logs(&mut logs);

    for log in logs {
        let Some(event) = decode_log(chain, &log, validation.phase.head).await? else {
            continue;
        };
        tournament.apply(event).with_context(|| {
            format!(
                "tournament {address} log {} at block {} does not fold",
                log.log_index.expect("harvest metadata was validated"),
                log.block_number.expect("harvest metadata was validated")
            )
        })?;
    }
    Ok(tournament)
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
}

impl HarvestValidation {
    fn new(phase: ReadPhase) -> Self {
        Self {
            phase,
            block_hashes: HashMap::new(),
            positions: HashSet::new(),
        }
    }

    fn observe(&mut self, log: &Log, expected_address: Address) -> Result<()> {
        let ReadPhase { from, head } = self.phase;
        let to = head.number;
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
        ensure!(
            block != head.number || block_hash == head.hash,
            "log at block {block} belongs to {block_hash}, not to the sampled head {}",
            head.hash
        );
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

/// Decodes one structural event; accounting events decode to `None`.
async fn decode_log(chain: &Chain, log: &Log, head: ChainHead) -> Result<Option<EventKind>> {
    let tournament = log.address();
    let topic = log
        .inner
        .topics()
        .first()
        .copied()
        .ok_or_else(|| anyhow!("tournament {tournament} emitted a log without a topic"))?;

    let kind = if topic == bindings::Tournament::CommitmentJoined::SIGNATURE_HASH {
        let event = bindings::Tournament::CommitmentJoined::decode_log(&log.inner)
            .context("malformed CommitmentJoined event")?;
        EventKind::CommitmentJoined {
            root: event.commitment.into(),
        }
    } else if topic == bindings::Tournament::MatchCreated::SIGNATURE_HASH {
        let event = bindings::Tournament::MatchCreated::decode_log(&log.inner)
            .context("malformed MatchCreated event")?;
        EventKind::MatchCreated {
            id: MatchID {
                commitment_one: event.one.into(),
                commitment_two: event.two.into(),
            },
            eliminable_at: event.eliminableAt,
        }
    } else if topic == bindings::Tournament::MatchAdvanced::SIGNATURE_HASH {
        let event = bindings::Tournament::MatchAdvanced::decode_log(&log.inner)
            .context("malformed MatchAdvanced event")?;
        EventKind::MatchAdvanced {
            match_id_hash: event.matchIdHash.into(),
            eliminable_at: event.eliminableAt,
        }
    } else if topic == bindings::Tournament::LeafMatchSealed::SIGNATURE_HASH {
        let event = bindings::Tournament::LeafMatchSealed::decode_log(&log.inner)
            .context("malformed LeafMatchSealed event")?;
        EventKind::LeafMatchSealed {
            match_id_hash: event.matchIdHash.into(),
            eliminable_at: event.eliminableAt,
        }
    } else if topic == bindings::Tournament::NewInnerTournament::SIGNATURE_HASH {
        let event = bindings::Tournament::NewInnerTournament::decode_log(&log.inner)
            .context("malformed NewInnerTournament event")?;
        EventKind::NewInnerTournament {
            match_id_hash: event.matchIdHash.into(),
            child: observer::read_descriptor(chain, event.childTournament, head).await?,
        }
    } else if topic == bindings::Tournament::MatchDeleted::SIGNATURE_HASH {
        let event = bindings::Tournament::MatchDeleted::decode_log(&log.inner)
            .context("malformed MatchDeleted event")?;
        let id = MatchID {
            commitment_one: event.one.into(),
            commitment_two: event.two.into(),
        };
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
        EventKind::MatchDeleted {
            match_id_hash: id.hash(),
            reason,
            winner,
        }
    } else if topic == bindings::Tournament::PartialBondRefund::SIGNATURE_HASH {
        bindings::Tournament::PartialBondRefund::decode_log(&log.inner)
            .context("malformed PartialBondRefund event")?;
        return Ok(None);
    } else if topic == bindings::Tournament::BondRecovered::SIGNATURE_HASH {
        bindings::Tournament::BondRecovered::decode_log(&log.inner)
            .context("malformed BondRecovered event")?;
        return Ok(None);
    } else {
        bail!(
            "tournament {tournament} emitted unknown event topic {topic}; current tournament event ABI required, deploy contracts and node across a coordinated version boundary"
        );
    };
    Ok(Some(kind))
}

#[cfg(test)]
mod tests {
    use alloy::{
        primitives::{Bytes, Log as PrimitiveLog, U256, keccak256},
        rpc::types::Block,
        sol_types::{SolCall, SolEvent},
        transports::mock::Asserter,
    };

    use super::*;
    use crate::{
        chain::recording::{Requests, recording_provider},
        merkle::Digest,
        tournament::{
            dispute::{CommitmentPosition, Event, MatchStatus},
            domain::{TournamentDescriptor, TournamentKind},
        },
    };

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
            startInstant: 100,
            allowance: 20,
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

    fn match_advanced_log(
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
            bindings::Tournament::MatchAdvanced {
                matchIdHash: id.hash().into(),
                otherParent: digest(91).into(),
                leftNode: digest(92).into(),
                segmentStartPosition: U256::ZERO,
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
        let join = |tournament, root| event(tournament, EventKind::CommitmentJoined { root });
        let dispute = Dispute::try_new(descriptor(root, 0, TournamentKind::NonLeaf))
            .unwrap()
            .apply_block([join(root, one)])
            .unwrap()
            .apply_block([
                join(root, two),
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
            .apply_block([join(child, child_one)])
            .unwrap()
            .apply_block([
                join(child, child_two),
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
            dispute,
        }
    }

    fn push_call_response<C: SolCall>(asserter: &Asserter, response: &C::Return) {
        asserter.push_success(&Bytes::from(C::abi_encode_returns(response)));
    }

    fn recording_chain() -> (Chain, Asserter, Requests) {
        let (provider, asserter, requests) = recording_provider();
        (Chain::new(provider, Vec::new()), asserter, requests)
    }

    #[test]
    fn harvest_validation_is_global_but_needs_no_transaction_metadata() {
        let range_head = head(12, 0x12);
        let root = address(1);
        let child = address(2);
        let phase = ReadPhase {
            from: 10,
            head: range_head,
        };
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
    async fn decoder_is_strict() {
        let root = address(1);
        let at = head(10, 0x10);
        let (chain, asserter, _) = recording_chain();
        let joined = join_log(root, at, 0, digest(10));
        assert_eq!(
            decode_log(&chain, &joined, at).await.unwrap(),
            Some(EventKind::CommitmentJoined { root: digest(10) })
        );

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
        assert_eq!(decode_log(&chain, &refund, at).await.unwrap(), None);
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
        let phase = ReadPhase { from: 10, head: at };
        let mut validation = HarvestValidation::new(phase);
        let loaded = extend_tournament(&chain, root, &mut validation)
            .await
            .unwrap();
        let dispute = Dispute::from_root(loaded);
        let child_tournament = dispute.tournament(&child).unwrap();
        assert!(child_tournament.commitment(&child_commitment).is_some());
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
        // alloy 2 serializes a `BlockId::Hash` without `require_canonical` as a
        // bare EIP-1898 hash string instead of a `{ "blockHash": ... }` object.
        assert_eq!(
            descriptor_call["params"][1],
            serde_json::json!(format!("{:#x}", at.hash))
        );
    }

    #[tokio::test]
    async fn a_child_resolved_in_range_is_never_fetched() {
        let fixture = active_recursive_dispute();
        let at = head(20, 0x20);
        let (chain, asserter, requests) = recording_chain();

        // The parent's resolution drops the child before its stream is due:
        // the mock serves one getLogs, so any child fetch fails the test.
        asserter.push_success(&vec![match_deleted_log(
            fixture.root,
            at,
            8,
            fixture.parent_match,
            MatchDeletionReason::ChildTournament,
            WinnerCommitment::One,
        )]);

        let phase = ReadPhase {
            from: at.number,
            head: at,
        };
        let mut validation = HarvestValidation::new(phase);
        let loaded = extend_tournament(&chain, fixture.dispute.into_root(), &mut validation)
            .await
            .unwrap();
        let dispute = Dispute::from_root(loaded);
        assert_eq!(
            dispute
                .root()
                .match_by_id_hash(&fixture.parent_match.hash())
                .unwrap()
                .status(),
            &MatchStatus::Resolved {
                reason: MatchDeletionReason::ChildTournament,
                winner: WinnerCommitment::One,
            }
        );
        assert!(dispute.tournament(&fixture.child).is_none());
        assert!(asserter.read_q().is_empty());
        assert_eq!(
            requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn finalized_progress_survives_latest_failure() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let commitment = digest(10);
        let (chain, asserter, _) = recording_chain();
        let mut reader = StateReader::new(chain, 40);

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![join_log(root, finalized, 0, commitment)]);
        asserter.push_failure_msg("latest unavailable");

        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(error.to_string().contains("latest unavailable"));
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
        let mut reader = StateReader::new(chain, 40);

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
        let mut reader = StateReader::new(chain, 40);

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
    async fn a_cold_reader_folds_the_same_solid_as_a_warm_one() {
        let root = address(1);
        let child = address(2);
        let first_finalized = head(41, 0x41);
        let discovered = head(42, 0x42);
        let second_finalized = head(43, 0x43);
        let id = MatchID {
            commitment_one: digest(10),
            commitment_two: digest(20),
        };
        let first_root_logs = vec![
            join_log(root, first_finalized, 0, id.commitment_one),
            join_log(root, first_finalized, 1, id.commitment_two),
            match_created_log(root, first_finalized, 2, id, 60),
        ];
        let second_root_logs = vec![new_inner_log(root, discovered, 0, id.hash(), child)];
        let child_logs = vec![join_log(child, second_finalized, 0, digest(30))];
        let log_ranges = |requests: &Requests| {
            requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request["method"] == "eth_getLogs")
                .map(|request| {
                    (
                        request["params"][0]["fromBlock"].clone(),
                        request["params"][0]["toBlock"].clone(),
                    )
                })
                .collect::<Vec<_>>()
        };

        let (chain, asserter, warm_requests) = recording_chain();
        let mut warm = StateReader::new(chain, 40);
        asserter.push_success(&Some(block(first_finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::NonLeaf),
        );
        asserter.push_success(&first_root_logs);
        asserter.push_success(&Some(block(first_finalized, B256::repeat_byte(0x40))));
        warm.fetch_from_root(root).await.unwrap();
        asserter.push_success(&Some(block(second_finalized, discovered.hash)));
        asserter.push_success(&second_root_logs);
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(1, TournamentKind::Leaf),
        );
        asserter.push_success(&child_logs);
        asserter.push_success(&Some(block(second_finalized, discovered.hash)));
        warm.fetch_from_root(root).await.unwrap();
        assert!(asserter.read_q().is_empty());

        let (chain, asserter, cold_requests) = recording_chain();
        let mut cold = StateReader::new(chain, 40);
        asserter.push_success(&Some(block(second_finalized, discovered.hash)));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::NonLeaf),
        );
        asserter.push_success(&[first_root_logs, second_root_logs].concat());
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(1, TournamentKind::Leaf),
        );
        asserter.push_success(&child_logs);
        asserter.push_success(&Some(block(second_finalized, discovered.hash)));
        cold.fetch_from_root(root).await.unwrap();
        assert!(asserter.read_q().is_empty());

        let (warm_head, warm_solid) = warm.solid().unwrap();
        let (cold_head, cold_solid) = cold.solid().unwrap();
        assert_eq!(warm_head, cold_head);
        assert_eq!(warm_solid, cold_solid);
        assert!(
            cold_solid
                .tournament(&child)
                .unwrap()
                .commitment(&digest(30))
                .is_some()
        );
        assert_eq!(
            log_ranges(&warm_requests),
            vec![
                (serde_json::json!("0x28"), serde_json::json!("0x29")),
                (serde_json::json!("0x2a"), serde_json::json!("0x2b")),
                (serde_json::json!("0x2a"), serde_json::json!("0x2b")),
            ]
        );
        assert_eq!(
            log_ranges(&cold_requests),
            vec![
                (serde_json::json!("0x28"), serde_json::json!("0x2b")),
                (serde_json::json!("0x28"), serde_json::json!("0x2b")),
            ],
            "a restart refolds every stream from the root's creation block"
        );
    }

    #[tokio::test]
    async fn a_fold_failure_drops_solid_and_the_next_tick_refolds() {
        let root = address(1);
        let first_finalized = head(41, 0x41);
        let second_finalized = head(43, 0x43);
        let id = MatchID {
            commitment_one: digest(10),
            commitment_two: digest(20),
        };
        let joins = vec![
            join_log(root, first_finalized, 0, id.commitment_one),
            join_log(root, first_finalized, 1, id.commitment_two),
        ];
        let created = match_created_log(root, first_finalized, 2, id, 60);
        let advanced = match_advanced_log(root, second_finalized, 0, id, 70);
        let (chain, asserter, requests) = recording_chain();
        let mut reader = StateReader::new(chain, 40);

        // The provider omits the match's creation from the first fold.
        asserter.push_success(&Some(block(first_finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&joins);
        asserter.push_success(&Some(block(first_finalized, B256::repeat_byte(0x40))));
        reader.fetch_from_root(root).await.unwrap();

        // A transport failure keeps Solid and retries the same range.
        asserter.push_success(&Some(block(second_finalized, B256::repeat_byte(0x42))));
        asserter.push_failure_msg("getLogs unavailable");
        assert!(reader.fetch_from_root(root).await.is_err());
        assert_eq!(reader.solid().unwrap().0, first_finalized);

        // The match's next event does not fold onto the gap: Solid goes.
        asserter.push_success(&Some(block(second_finalized, B256::repeat_byte(0x42))));
        asserter.push_success(&vec![advanced.clone()]);
        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(error.downcast_ref::<DisputeError>().is_some(), "{error:#}");
        assert!(reader.solid().is_none());

        // The next tick refolds from the root's creation block.
        asserter.push_success(&Some(block(second_finalized, B256::repeat_byte(0x42))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&[joins, vec![created, advanced]].concat());
        asserter.push_success(&Some(block(second_finalized, B256::repeat_byte(0x42))));
        reader.fetch_from_root(root).await.unwrap();
        let (solid_head, solid) = reader.solid().unwrap();
        assert_eq!(solid_head, second_finalized);
        assert!(solid.root().match_by_id_hash(&id.hash()).is_some());
        assert!(asserter.read_q().is_empty());

        let ranges = requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request["method"] == "eth_getLogs")
            .map(|request| {
                (
                    request["params"][0]["fromBlock"].clone(),
                    request["params"][0]["toBlock"].clone(),
                )
            })
            .collect::<Vec<_>>();
        let range = |from: &str, to: &str| (serde_json::json!(from), serde_json::json!(to));
        assert_eq!(
            ranges,
            vec![
                range("0x28", "0x29"),
                range("0x2a", "0x2b"),
                range("0x2a", "0x2b"),
                range("0x28", "0x2b"),
            ]
        );
    }

    /// A missed finalized seal still folds, so only the Hero's pinned phase
    /// read sees it, and its failed tick hands that error back.
    #[tokio::test]
    async fn a_phase_contradiction_drops_solid_and_the_next_tick_refolds() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let id = MatchID {
            commitment_one: digest(10),
            commitment_two: digest(20),
        };
        // The provider omits the match's LeafMatchSealed.
        let logs = vec![
            join_log(root, finalized, 0, id.commitment_one),
            join_log(root, finalized, 1, id.commitment_two),
            match_created_log(root, finalized, 2, id, 60),
        ];
        let (chain, asserter, requests) = recording_chain();
        let mut reader = StateReader::new(chain.clone(), 40);
        let cold_fold = || {
            asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
            push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
                &asserter,
                &descriptor_response(0, TournamentKind::Leaf),
            );
            asserter.push_success(&logs);
            asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        };
        cold_fold();
        reader.fetch_from_root(root).await.unwrap();

        push_call_response::<bindings::Tournament::classifyMatchTimeoutCall>(
            &asserter,
            &bindings::Tournament::classifyMatchTimeoutReturn {
                actualPhase: 3,
                outcome: 0,
                deferredCharge: 0,
            },
        );
        let (solid_head, solid) = reader.solid().unwrap();
        let match_ = solid.root().match_by_id_hash(&id.hash()).unwrap();
        let contradiction = observer::read_match(&chain, solid.root(), match_, solid_head)
            .await
            .unwrap_err();
        let as_the_hero_fails = |source| {
            anyhow::Error::from(crate::hero::context::ContextError::MatchRead {
                tournament: root,
                match_id_hash: id.hash(),
                source,
            })
        };

        // Any other failure of the same read keeps Solid.
        reader.forget_contradicted_solid(&as_the_hero_fails(anyhow!("call timed out")));
        reader.forget_contradicted_solid(&as_the_hero_fails(
            observer::ObserverError::ResolvedMatchSelected {
                match_id_hash: id.hash(),
            }
            .into(),
        ));
        assert_eq!(reader.solid().unwrap().0, finalized);

        reader.forget_contradicted_solid(&as_the_hero_fails(contradiction));
        assert!(reader.solid().is_none());

        cold_fold();
        reader.fetch_from_root(root).await.unwrap();
        assert!(asserter.read_q().is_empty());
        let ranges = requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request["method"] == "eth_getLogs")
            .map(|request| {
                (
                    request["params"][0]["fromBlock"].clone(),
                    request["params"][0]["toBlock"].clone(),
                )
            })
            .collect::<Vec<_>>();
        let creation = (serde_json::json!("0x28"), serde_json::json!("0x29"));
        assert_eq!(ranges, vec![creation.clone(), creation]);
    }

    #[tokio::test]
    async fn a_tail_log_at_the_sampled_head_must_carry_its_hash() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let latest = head(43, 0x43);
        let (chain, asserter, _) = recording_chain();
        let mut reader = StateReader::new(chain, 40);

        asserter.push_success(&Some(block(finalized, B256::repeat_byte(0x40))));
        push_call_response::<bindings::Tournament::tournamentDescriptorCall>(
            &asserter,
            &descriptor_response(0, TournamentKind::Leaf),
        );
        asserter.push_success(&vec![join_log(root, finalized, 0, digest(10))]);
        asserter.push_success(&Some(block(latest, B256::repeat_byte(0x42))));
        // The tail is served from a fork whose block 43 is not the head.
        asserter.push_success(&vec![join_log(root, head(43, 0x99), 0, digest(20))]);

        let error = reader.fetch_from_root(root).await.unwrap_err();
        assert!(
            error
                .to_string()
                .contains(&format!("sampled head {}", latest.hash)),
            "{error:#}"
        );
        let (solid_head, solid) = reader.solid().unwrap();
        assert_eq!(solid_head, finalized);
        assert!(solid.root().commitment(&digest(20)).is_none());
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn finalized_same_height_hash_change_retries() {
        let root = address(1);
        let finalized = head(41, 0x41);
        let (chain, asserter, _) = recording_chain();
        let mut reader = StateReader::new(chain, 40);

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
