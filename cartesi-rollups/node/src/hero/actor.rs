//! Production Hero orchestration: observe, project, plan, prepare, and
//! yield the tick's wave contribution for the epoch manager to submit.

use std::sync::Arc;

use ::log::{debug, error, info};

use crate::{
    chain::{Chain, ChainHead},
    engine::{DisputeSource, Positioner, RulerFactory, stf::ProvingStf},
    hero::{
        action::{PreparedArenaAction, prepare},
        context::HeroContext,
        error::Result,
        gc_planner::plan_gc,
        planner::{HeroDecision, HeroTerminal, plan_hero},
    },
    merkle::Digest,
    provider::LaneRequest,
    storage::Storage,
    tournament::{ArenaSender, DisputeState, StateReader, domain::GcIntent},
};
use alloy::primitives::Address;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TournamentResult {
    Lost,
    Running,
    Won,
    FailedNoWinner,
}

/// One dispute tick's outcome: the standing result plus the tick's
/// wave contribution - the hero action first (when one is legal),
/// then every currently legal cleanup, innermost-first. Position in
/// the composed wave is nonce order, and nonce order is priority.
#[derive(Clone, Debug)]
pub struct HeroTick {
    result: TournamentResult,
    wave: Vec<LaneRequest>,
}

impl HeroTick {
    pub(crate) fn new(result: TournamentResult, wave: Vec<LaneRequest>) -> Self {
        Self { result, wave }
    }

    pub const fn result(&self) -> TournamentResult {
        self.result
    }

    pub fn into_wave(self) -> Vec<LaneRequest> {
        self.wave
    }
}

/// Generic over the ruler factory so action preparation runs against the toy
/// source in unit tests while production uses [`Positioner`].
pub struct Hero<AS: ArenaSender, F: RulerFactory = Positioner> {
    arena_sender: Arc<AS>,
    source: DisputeSource<F>,
    epoch: u64,
    epoch_initial_hash: Digest,
    root_tournament: Address,
    reader: StateReader,
}

impl<AS: ArenaSender> Hero<AS> {
    pub fn new(
        arena_sender: Arc<AS>,
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        mut storage: Storage,
        epoch_number: u64,
    ) -> Result<Self> {
        let work_dir = storage.epoch_directory(epoch_number)?;
        let epoch_initial_hash = Digest::from_digest(
            &storage
                .snapshot_hash(epoch_number, 0)?
                .expect("snapshot is inserted atomically with settlement info"),
        )
        .map_err(anyhow::Error::from)?;
        let reader_storage = Storage::new(storage.state_dir())?;
        let source = DisputeSource::on_store(storage, epoch_number, work_dir.join("engine"))?;
        let reader = StateReader::new(chain, block_created_number, reader_storage)?;

        Ok(Self {
            arena_sender,
            source,
            epoch: epoch_number,
            epoch_initial_hash,
            root_tournament,
            reader,
        })
    }
}

impl<AS: ArenaSender, F: RulerFactory + Send> Hero<AS, F>
where
    F::S: ProvingStf,
{
    pub async fn tick(&mut self) -> Result<HeroTick> {
        let dispute = self.reader.fetch_from_root(self.root_tournament).await?;
        let context = HeroContext::assemble(
            self.epoch,
            self.epoch_initial_hash,
            &dispute.fold,
            &dispute.observations,
            &mut self.source,
        )
        .map_err(anyhow::Error::from)?;
        let decision = plan_hero(context.snapshot());

        let mut result = TournamentResult::Running;
        let mut wave = Vec::new();
        match decision {
            HeroDecision::Act(intent) => {
                let action =
                    prepare(intent, &context, &mut self.source).map_err(anyhow::Error::from)?;
                wave.push(
                    request_prepared(self.arena_sender.as_ref(), action, dispute.head).await?,
                );
            }
            HeroDecision::Wait(reason) => {
                debug!("Hero waits: {reason:?}");
            }
            HeroDecision::Terminal(terminal) => {
                result = match terminal {
                    HeroTerminal::Won => {
                        info!("Hero won tournament {}", self.root_tournament);
                        TournamentResult::Won
                    }
                    HeroTerminal::Lost => {
                        error!("Hero lost tournament {}", self.root_tournament);
                        TournamentResult::Lost
                    }
                    HeroTerminal::FailedNoWinner => {
                        error!(
                            "root tournament {} finished without a winner",
                            self.root_tournament
                        );
                        TournamentResult::FailedNoWinner
                    }
                };
            }
        }

        // Cleanup rides behind the hero action in the same wave. A
        // lost or winnerless dispute plans nothing more: the node is
        // done with this epoch's tournament.
        if matches!(result, TournamentResult::Running | TournamentResult::Won) {
            wave.extend(self.gc_requests(&dispute)?);
        }
        Ok(HeroTick::new(result, wave))
    }

    /// Every currently legal cleanup, innermost-first, as lane
    /// requests. One live match yields at most one intent, and an
    /// eliminable child's tournament is never recursed into, so a
    /// plan cannot invalidate its own suffix; follow-on cleanup that
    /// an elimination unlocks arrives with the next observation.
    fn gc_requests(&self, dispute: &DisputeState) -> Result<Vec<LaneRequest>> {
        let intents = plan_gc(&dispute.fold, &dispute.observations).map_err(anyhow::Error::from)?;
        Ok(intents
            .into_iter()
            .map(|intent| {
                info!("plan cleanup intent: {intent:?}");
                match intent {
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
                }
            })
            .collect())
    }
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
