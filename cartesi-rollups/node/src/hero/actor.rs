//! Production Hero orchestration: observe, project, plan, prepare, and
//! yield the tick's wave contribution for the epoch manager to submit.

use std::{collections::HashMap, sync::Arc, time::Instant};

use ::log::{debug, info};

use crate::{
    chain::{Chain, ChainHead},
    engine::{DisputeSource, Positioner},
    hero::{
        action::{PreparedArenaAction, prepare},
        context::{EpochAnchors, HeroContext},
        error::{ReactError, Result},
        gc_planner::plan_gc,
        planner::{HeroDecision, HeroIntent, HeroTerminal, JoinIntent, plan_hero},
    },
    merkle::Digest,
    provider::LaneRequest,
    storage::Storage,
    sync::ShutdownSignal,
    tournament::{
        ArenaSender, StateReader,
        dispute::Dispute,
        domain::{GcIntent, TournamentStanding},
        observer::read_standings,
    },
};
use alloy::primitives::Address;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TournamentResult {
    Lost,
    Running,
    Won,
    FailedNoWinner,
}

/// One dispute tick's outcome and its optional lane request.
///
/// Hero work and cleanup never share a wave: at most one request leaves a
/// tick, and a cleanup is selected only when that tick has no Hero action.
#[derive(Clone, Debug)]
pub struct HeroTick {
    result: TournamentResult,
    head: ChainHead,
    wave: Vec<LaneRequest>,
}

impl HeroTick {
    pub(crate) fn new(result: TournamentResult, head: ChainHead, wave: Vec<LaneRequest>) -> Self {
        Self { result, head, wave }
    }

    pub const fn result(&self) -> TournamentResult {
        self.result
    }

    /// The latest head the result was observed at. Settlement reads its
    /// views there, so a won root and the staged winner describe one block.
    pub const fn head(&self) -> ChainHead {
        self.head
    }

    pub fn into_wave(self) -> Vec<LaneRequest> {
        self.wave
    }
}

/// The production actor owns one epoch's real machine source.
pub struct Hero<AS: ArenaSender> {
    arena_sender: Arc<AS>,
    source: DisputeSource<Positioner>,
    epoch: u64,
    anchors: EpochAnchors,
    root_tournament: Address,
    reader: StateReader,
    #[cfg(test)]
    reobservations: usize,
}

/// One observation: the latest foam, its standings, and the Hero's path
/// assembled on it, local commitments included.
struct Observation {
    head: ChainHead,
    foam: Dispute,
    standings: HashMap<Address, TournamentStanding>,
    context: HeroContext,
}

impl<AS: ArenaSender> Hero<AS> {
    /// The node's Hero: its machine work stops once `shutdown` is
    /// requested, keeping what it stored for the restarted node.
    pub fn new(
        arena_sender: Arc<AS>,
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        mut storage: Storage,
        epoch_number: u64,
        shutdown: ShutdownSignal,
    ) -> Result<Self> {
        let engine_dir = storage.epoch_directory(epoch_number)?.join("engine");
        let mut hero = Self::build(
            arena_sender,
            chain,
            root_tournament,
            block_created_number,
            storage,
            epoch_number,
            engine_dir,
        )?;
        hero.source.stop_on(shutdown);
        Ok(hero)
    }

    /// The harness adversary: this actor over a test-only tail overlay.
    /// It needs its own engine directory, since a source's positioner
    /// clears the work directories it numbers.
    #[cfg(test)]
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn with_tail(
        arena_sender: Arc<AS>,
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        storage: Storage,
        epoch_number: u64,
        engine_dir: std::path::PathBuf,
        tail: crate::engine::Tail,
    ) -> Result<Self> {
        let mut hero = Self::build(
            arena_sender,
            chain,
            root_tournament,
            block_created_number,
            storage,
            epoch_number,
            engine_dir,
        )?;
        hero.source.set_tail(tail);
        Ok(hero)
    }

    fn build(
        arena_sender: Arc<AS>,
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        mut storage: Storage,
        epoch_number: u64,
        engine_dir: std::path::PathBuf,
    ) -> Result<Self> {
        let initial_hash = Digest::from_digest(
            &storage
                .snapshot_hash(epoch_number, 0)?
                .expect("snapshot is inserted atomically with settlement info"),
        )
        .map_err(anyhow::Error::from)?;
        let anchors = EpochAnchors {
            initial_hash,
            geometry: storage.sling_config()?.geometry,
        };
        let source = DisputeSource::on_store(storage, epoch_number, engine_dir)?;
        let reader = StateReader::new(chain, block_created_number);

        Ok(Self {
            arena_sender,
            source,
            epoch: epoch_number,
            anchors,
            root_tournament,
            reader,
            #[cfg(test)]
            reobservations: 0,
        })
    }

    /// Ticks whose observation was repeated after a build.
    #[cfg(test)]
    pub(crate) fn reobservations(&self) -> usize {
        self.reobservations
    }

    pub async fn tick(&mut self) -> Result<HeroTick> {
        let ticked = self.plan_tick().await;
        if let Err(ReactError::Anyhow { source }) = &ticked {
            self.reader.forget_contradicted_solid(source);
        }
        ticked
    }

    async fn plan_tick(&mut self) -> Result<HeroTick> {
        // The node's share of a response's time runs from reading the chain
        // through commitment builds (context assembly builds the local
        // material) and proving to submission; operators compare it with
        // the deployed budgets.
        let started = Instant::now();
        let trips = self.source.trips();
        let mut observed = self.observe().await?;
        if self.source.trips() != trips {
            // Assembly ran machine work (tens of minutes for a two-level
            // leaf) while the chain moved on: a child may have finalized for
            // the join, and the head may have left a pruned provider's state
            // window. Plan from a fresh observation, whose assembly reuses
            // the build. Once: act on it even if it built again.
            debug!("assembly ran machine work; observing again before planning");
            #[cfg(test)]
            {
                self.reobservations += 1;
            }
            observed = self.observe().await?;
        }
        let Observation {
            head: latest_head,
            foam,
            standings: foam_standings,
            context: foam_context,
        } = observed;
        let chain = self.reader.chain().clone();
        let foam_decision = plan_hero(foam_context.snapshot());

        // Joining commits to the epoch's computation. Latest may suppress a
        // join that is already mined or no longer possible, but only Solid may
        // supply its payload. All deadline-sensitive actions use Foam.
        let (context, decision, action_head) = if let HeroDecision::Act(HeroIntent::Join(
            foam_join,
        )) = foam_decision
        {
            let (solid_head, solid) = self
                .reader
                .solid()
                .expect("fetch_from_root initializes Solid");
            let solid_standings = read_standings(&chain, solid, solid_head).await?;
            let solid_context = HeroContext::assemble(
                &chain,
                solid_head,
                self.epoch,
                &self.anchors,
                solid,
                &solid_standings,
                &mut self.source,
            )
            .await
            .map_err(anyhow::Error::from)?;
            let solid_decision = plan_hero(solid_context.snapshot());
            if !is_exact_join(solid_decision, foam_join) {
                // Keep the lane empty while Solid catches up. A Foam cleanup
                // here could still be pending when the finalized join is due.
                debug!(
                    "latest proposed {foam_join:?}, which Solid does not support exactly; retry next tick"
                );
                report_slow_tick(started, "the join waits for finality");
                return Ok(HeroTick::new(
                    TournamentResult::Running,
                    latest_head,
                    Vec::new(),
                ));
            }
            (solid_context, solid_decision, solid_head)
        } else {
            (foam_context, foam_decision, latest_head)
        };

        let mut result = TournamentResult::Running;
        let mut wave = Vec::new();
        match decision {
            HeroDecision::Act(intent) => {
                let action = super::machine_work(|| prepare(intent, &context, &mut self.source))
                    .map_err(anyhow::Error::from)?;
                info!(
                    "prepared {intent:?} in {:.1?} (reads, builds and proving), observed at block {}",
                    started.elapsed(),
                    action_head.number
                );
                wave.push(request_prepared(self.arena_sender.as_ref(), action, action_head).await?);
            }
            HeroDecision::Wait(reason) => {
                debug!("Hero waits: {reason:?}");
                report_slow_tick(started, format!("{reason:?}"));
            }
            HeroDecision::Terminal(terminal) => {
                // The epoch manager logs the result, once per tick.
                result = match terminal {
                    HeroTerminal::Won => TournamentResult::Won,
                    HeroTerminal::Lost => TournamentResult::Lost,
                    HeroTerminal::FailedNoWinner => TournamentResult::FailedNoWinner,
                };
            }
        }

        if result == TournamentResult::Running
            && wave.is_empty()
            && let Some(request) = self.gc_request(&foam, &foam_standings, latest_head.number)?
        {
            wave.push(request);
        }
        Ok(HeroTick::new(result, latest_head, wave))
    }

    async fn observe(&mut self) -> Result<Observation> {
        let (head, foam) = self.reader.fetch_from_root(self.root_tournament).await?;
        let chain = self.reader.chain().clone();
        let standings = read_standings(&chain, &foam, head).await?;
        let context = HeroContext::assemble(
            &chain,
            head,
            self.epoch,
            &self.anchors,
            &foam,
            &standings,
            &mut self.source,
        )
        .await
        .map_err(anyhow::Error::from)?;
        Ok(Observation {
            head,
            foam,
            standings,
            context,
        })
    }

    fn gc_request(
        &self,
        dispute: &Dispute,
        standings: &HashMap<Address, TournamentStanding>,
        at: u64,
    ) -> Result<Option<LaneRequest>> {
        let Some(intent) = plan_gc(dispute, standings, at).map_err(anyhow::Error::from)? else {
            return Ok(None);
        };
        info!("plan cleanup intent: {intent:?}");
        Ok(Some(match intent {
            GcIntent::EliminateMatch {
                tournament,
                match_id,
            } => self.arena_sender.eliminate_match(tournament, match_id),
            GcIntent::EliminateChild {
                parent_tournament,
                child_tournament,
            } => self
                .arena_sender
                .eliminate_inner_tournament(parent_tournament, child_tournament),
        }))
    }
}

/// A tick that does local work without acting still spends the node's
/// time, most often a commitment build ahead of a join that waits for
/// finality; report it when it is not instant.
fn report_slow_tick(started: Instant, outcome: impl std::fmt::Display) {
    let elapsed = started.elapsed();
    if elapsed >= std::time::Duration::from_secs(1) {
        info!("Hero tick took {elapsed:.1?} without acting: {outcome}");
    }
}

fn is_exact_join(decision: HeroDecision, expected: JoinIntent) -> bool {
    matches!(decision, HeroDecision::Act(HeroIntent::Join(actual)) if actual == expected)
}

/// The only production dispatch seam for a prepared Hero action. Matching one
/// enum value yields exactly one mutation request; no error path selects a
/// second verb from the same observation.
async fn request_prepared<AS: ArenaSender>(
    arena_sender: &AS,
    action: PreparedArenaAction,
    head: ChainHead,
) -> Result<LaneRequest> {
    // These concise action markers are also synchronization points for the
    // crash-recovery e2e scenarios. Emit them as the request enters the
    // wave, immediately before the tick submits it.
    Ok(match action {
        PreparedArenaAction::Join {
            tournament,
            proof_last,
            left_child,
            right_child,
        } => {
            info!("submit Hero action: join tournament {tournament}");
            let bond = arena_sender.bond_value(tournament, head.block_id()).await?;
            arena_sender.join_tournament(tournament, &proof_last, left_child, right_child, bond)
        }
        PreparedArenaAction::ClaimTimeout {
            tournament,
            match_id,
            left_node,
            right_node,
        } => {
            info!(
                "submit Hero action: claim timeout for match {} in tournament {tournament}",
                match_id.hash()
            );
            arena_sender.win_timeout_match(tournament, match_id, left_node, right_node)
        }
        PreparedArenaAction::Advance {
            tournament,
            match_id,
            left_node,
            right_node,
            new_left_node,
            new_right_node,
        } => {
            info!(
                "submit Hero action: advance match {} in tournament {tournament}",
                match_id.hash()
            );
            arena_sender.advance_match(
                tournament,
                match_id,
                left_node,
                right_node,
                new_left_node,
                new_right_node,
            )
        }
        PreparedArenaAction::SealLeaf {
            tournament,
            match_id,
            left_leaf,
            right_leaf,
            agree_state_proof,
        } => {
            info!(
                "submit Hero action: seal leaf match {} in tournament {tournament}",
                match_id.hash()
            );
            arena_sender.seal_leaf_match(
                tournament,
                match_id,
                left_leaf,
                right_leaf,
                &agree_state_proof,
            )
        }
        PreparedArenaAction::CreateChild {
            tournament,
            match_id,
            left_leaf,
            right_leaf,
            agree_state_proof,
        } => {
            info!(
                "submit Hero action: create child for match {} in tournament {tournament}",
                match_id.hash()
            );
            arena_sender.seal_inner_match(
                tournament,
                match_id,
                left_leaf,
                right_leaf,
                &agree_state_proof,
            )
        }
        PreparedArenaAction::ProveLeaf {
            tournament,
            match_id,
            left_node,
            right_node,
            proof,
        } => {
            info!(
                "submit Hero action: prove leaf match {} in tournament {tournament}",
                match_id.hash()
            );
            arena_sender.win_leaf_match(tournament, match_id, left_node, right_node, proof)
        }
        PreparedArenaAction::PropagateChild {
            parent_tournament,
            child_tournament,
            left_node,
            right_node,
        } => {
            info!(
                "submit Hero action: propagate child {child_tournament} into tournament {parent_tournament}"
            );
            arena_sender.win_inner_match(parent_tournament, child_tournament, left_node, right_node)
        }
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use alloy::{eips::BlockId, primitives::U256, rpc::types::TransactionRequest};
    use async_trait::async_trait;

    use super::*;
    use crate::{
        merkle::MerkleProof,
        tournament::{MachineProof, MatchID},
    };

    fn stub(label: &str) -> LaneRequest {
        (label.to_string(), TransactionRequest::default())
    }

    /// Request stubs labeled like the production builders, plus a bond
    /// read counter: only the join arm may pay for that read.
    #[derive(Default)]
    struct RecordingArena {
        bond_reads: Mutex<usize>,
    }

    impl RecordingArena {
        fn bond_reads(&self) -> usize {
            std::mem::take(&mut *self.bond_reads.lock().unwrap())
        }
    }

    #[async_trait]
    impl ArenaSender for RecordingArena {
        fn join_tournament(
            &self,
            _tournament: Address,
            _proof: &MerkleProof,
            _left_child: Digest,
            _right_child: Digest,
            _bond_value: U256,
        ) -> LaneRequest {
            stub("join")
        }

        fn advance_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_node: Digest,
            _right_node: Digest,
            _new_left_node: Digest,
            _new_right_node: Digest,
        ) -> LaneRequest {
            stub("advance")
        }

        fn seal_inner_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_leaf: Digest,
            _right_leaf: Digest,
            _initial_hash_proof: &MerkleProof,
        ) -> LaneRequest {
            stub("create_child")
        }

        fn win_inner_match(
            &self,
            _tournament: Address,
            _child_tournament: Address,
            _left_node: Digest,
            _right_node: Digest,
        ) -> LaneRequest {
            stub("propagate_child")
        }

        fn win_timeout_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_node: Digest,
            _right_node: Digest,
        ) -> LaneRequest {
            stub("claim_timeout")
        }

        fn seal_leaf_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_leaf: Digest,
            _right_leaf: Digest,
            _initial_hash_proof: &MerkleProof,
        ) -> LaneRequest {
            stub("seal_leaf")
        }

        fn win_leaf_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_node: Digest,
            _right_node: Digest,
            _proofs: MachineProof,
        ) -> LaneRequest {
            stub("prove_leaf")
        }

        fn eliminate_match(&self, _tournament: Address, _match_id: MatchID) -> LaneRequest {
            stub("eliminate_match")
        }

        fn eliminate_inner_tournament(
            &self,
            _tournament: Address,
            _inner_tournament: Address,
        ) -> LaneRequest {
            stub("eliminate_child")
        }

        async fn bond_value(&self, _tournament: Address, _at: BlockId) -> Result<U256> {
            *self.bond_reads.lock().unwrap() += 1;
            Ok(U256::from(7))
        }
    }

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn match_id() -> MatchID {
        MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        }
    }

    fn head() -> ChainHead {
        ChainHead {
            number: 9,
            hash: alloy::primitives::B256::repeat_byte(9),
        }
    }

    #[test]
    fn solid_must_support_the_exact_foam_join() {
        let expected = JoinIntent {
            tournament: address(1),
            commitment: digest(1),
        };
        assert!(is_exact_join(
            HeroDecision::Act(HeroIntent::Join(expected)),
            expected
        ));
        assert!(!is_exact_join(
            HeroDecision::Act(HeroIntent::Join(JoinIntent {
                tournament: address(2),
                commitment: expected.commitment,
            })),
            expected
        ));
        assert!(!is_exact_join(
            HeroDecision::Act(HeroIntent::Join(JoinIntent {
                tournament: expected.tournament,
                commitment: digest(2),
            })),
            expected
        ));
    }

    #[tokio::test]
    async fn each_prepared_variant_yields_exactly_one_request() {
        let arena = RecordingArena::default();
        let tournament = address(1);
        let child = address(2);
        let proof = || MerkleProof::leaf(digest(3), U256::ZERO);

        let (label, _) = request_prepared(
            &arena,
            PreparedArenaAction::Join {
                tournament,
                proof_last: proof(),
                left_child: digest(4),
                right_child: digest(5),
            },
            head(),
        )
        .await
        .unwrap();
        assert_eq!((arena.bond_reads(), label.as_str()), (1, "join"));

        let actions = [
            (
                PreparedArenaAction::ClaimTimeout {
                    tournament,
                    match_id: match_id(),
                    left_node: digest(4),
                    right_node: digest(5),
                },
                "claim_timeout",
            ),
            (
                PreparedArenaAction::Advance {
                    tournament,
                    match_id: match_id(),
                    left_node: digest(4),
                    right_node: digest(5),
                    new_left_node: digest(6),
                    new_right_node: digest(7),
                },
                "advance",
            ),
            (
                PreparedArenaAction::SealLeaf {
                    tournament,
                    match_id: match_id(),
                    left_leaf: digest(4),
                    right_leaf: digest(5),
                    agree_state_proof: proof(),
                },
                "seal_leaf",
            ),
            (
                PreparedArenaAction::CreateChild {
                    tournament,
                    match_id: match_id(),
                    left_leaf: digest(4),
                    right_leaf: digest(5),
                    agree_state_proof: proof(),
                },
                "create_child",
            ),
            (
                PreparedArenaAction::ProveLeaf {
                    tournament,
                    match_id: match_id(),
                    left_node: digest(4),
                    right_node: digest(5),
                    proof: vec![1, 2, 3],
                },
                "prove_leaf",
            ),
            (
                PreparedArenaAction::PropagateChild {
                    parent_tournament: tournament,
                    child_tournament: child,
                    left_node: digest(4),
                    right_node: digest(5),
                },
                "propagate_child",
            ),
        ];

        for (action, expected) in actions {
            let (label, _) = request_prepared(&arena, action, head()).await.unwrap();
            assert_eq!((arena.bond_reads(), label.as_str()), (0, expected));
        }
    }
}
