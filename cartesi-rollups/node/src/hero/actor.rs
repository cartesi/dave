//! Production Hero orchestration: observe, project, plan, prepare, submit once.

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HeroTick {
    result: TournamentResult,
    action_attempted: bool,
    gc_intent: Option<GcIntent>,
}

impl HeroTick {
    pub(crate) const fn new(
        result: TournamentResult,
        action_attempted: bool,
        gc_intent: Option<GcIntent>,
    ) -> Self {
        Self {
            result,
            action_attempted,
            gc_intent,
        }
    }

    pub const fn result(self) -> TournamentResult {
        self.result
    }

    pub const fn action_attempted(self) -> bool {
        self.action_attempted
    }

    pub const fn gc_intent(self) -> Option<GcIntent> {
        self.gc_intent
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

        match decision {
            HeroDecision::Act(intent) => {
                let action =
                    prepare(intent, &context, &mut self.source).map_err(anyhow::Error::from)?;
                submit_prepared(self.arena_sender.as_ref(), action, dispute.head).await?;
                Ok(HeroTick::new(TournamentResult::Running, true, None))
            }
            HeroDecision::Wait(reason) => {
                debug!("Hero waits: {reason:?}");
                Ok(HeroTick::new(
                    TournamentResult::Running,
                    false,
                    plan_one_gc(&dispute)?,
                ))
            }
            HeroDecision::Terminal(terminal) => {
                let result = match terminal {
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
                let gc_intent = (result == TournamentResult::Won)
                    .then(|| plan_one_gc(&dispute))
                    .transpose()?
                    .flatten();
                Ok(HeroTick::new(result, false, gc_intent))
            }
        }
    }

    /// Submit one cleanup that was planned only after Hero policy examined the
    /// same accepted observation. The shared transaction lane preserves that
    /// priority across ticks by replacing the same mined nonce.
    pub(crate) async fn submit_gc(&mut self, intent: GcIntent) -> Result<()> {
        info!("submit one bounded GC intent: {intent:?}");
        match intent {
            GcIntent::EliminateMatch {
                tournament,
                match_id,
            } => {
                self.arena_sender
                    .eliminate_match(tournament, match_id)
                    .await
            }
            GcIntent::EliminateChild {
                parent_tournament,
                child_tournament,
            } => {
                self.arena_sender
                    .eliminate_inner_tournament(parent_tournament, child_tournament)
                    .await
            }
        }
    }
}

fn plan_one_gc(dispute: &DisputeState) -> Result<Option<GcIntent>> {
    Ok(plan_gc(&dispute.fold, &dispute.observations)
        .map_err(anyhow::Error::from)?
        .into_iter()
        .next())
}

/// The only production dispatch seam for a prepared Hero action. Matching one
/// enum value invokes exactly one mutation method; no error path selects a
/// second verb from the same observation.
async fn submit_prepared<AS: ArenaSender>(
    arena_sender: &AS,
    action: PreparedArenaAction,
    head: ChainHead,
) -> Result<()> {
    // These concise action markers are also synchronization points for the
    // crash-recovery e2e scenarios. Emit them immediately before submission.
    match action {
        PreparedArenaAction::Join {
            tournament,
            proof_last,
            left_child,
            right_child,
        } => {
            info!("submit Hero action: join tournament {tournament}");
            let bond = arena_sender.bond_value(tournament, head.block_id()).await?;
            arena_sender
                .join_tournament(tournament, &proof_last, left_child, right_child, bond)
                .await
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
            arena_sender
                .win_timeout_match(tournament, match_id, left_node, right_node)
                .await
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
            arena_sender
                .advance_match(
                    tournament,
                    match_id,
                    left_node,
                    right_node,
                    new_left_node,
                    new_right_node,
                )
                .await
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
            arena_sender
                .seal_leaf_match(
                    tournament,
                    match_id,
                    left_leaf,
                    right_leaf,
                    &agree_state_proof,
                )
                .await
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
            arena_sender
                .seal_inner_match(
                    tournament,
                    match_id,
                    left_leaf,
                    right_leaf,
                    &agree_state_proof,
                )
                .await
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
            arena_sender
                .win_leaf_match(tournament, match_id, left_node, right_node, proof)
                .await
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
            arena_sender
                .win_inner_match(parent_tournament, child_tournament, left_node, right_node)
                .await
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use alloy::{eips::BlockId, primitives::U256};
    use async_trait::async_trait;

    use super::*;
    use crate::{
        merkle::MerkleProof,
        tournament::{MachineProof, MatchID},
    };

    #[derive(Default)]
    struct RecordingArena {
        bond_reads: Mutex<usize>,
        mutations: Mutex<Vec<&'static str>>,
    }

    impl RecordingArena {
        fn record(&self, mutation: &'static str) {
            self.mutations.lock().unwrap().push(mutation);
        }

        fn take(&self) -> (usize, Vec<&'static str>) {
            let reads = std::mem::take(&mut *self.bond_reads.lock().unwrap());
            let mutations = std::mem::take(&mut *self.mutations.lock().unwrap());
            (reads, mutations)
        }
    }

    #[async_trait]
    impl ArenaSender for RecordingArena {
        async fn join_tournament(
            &self,
            _tournament: Address,
            _proof: &MerkleProof,
            _left_child: Digest,
            _right_child: Digest,
            _bond_value: U256,
        ) -> Result<()> {
            self.record("join");
            Ok(())
        }

        async fn advance_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_node: Digest,
            _right_node: Digest,
            _new_left_node: Digest,
            _new_right_node: Digest,
        ) -> Result<()> {
            self.record("advance");
            Ok(())
        }

        async fn seal_inner_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_leaf: Digest,
            _right_leaf: Digest,
            _initial_hash_proof: &MerkleProof,
        ) -> Result<()> {
            self.record("create_child");
            Ok(())
        }

        async fn win_inner_match(
            &self,
            _tournament: Address,
            _child_tournament: Address,
            _left_node: Digest,
            _right_node: Digest,
        ) -> Result<()> {
            self.record("propagate_child");
            Ok(())
        }

        async fn win_timeout_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_node: Digest,
            _right_node: Digest,
        ) -> Result<()> {
            self.record("claim_timeout");
            Ok(())
        }

        async fn seal_leaf_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_leaf: Digest,
            _right_leaf: Digest,
            _initial_hash_proof: &MerkleProof,
        ) -> Result<()> {
            self.record("seal_leaf");
            Ok(())
        }

        async fn win_leaf_match(
            &self,
            _tournament: Address,
            _match_id: MatchID,
            _left_node: Digest,
            _right_node: Digest,
            _proofs: MachineProof,
        ) -> Result<()> {
            self.record("prove_leaf");
            Ok(())
        }

        async fn eliminate_match(&self, _tournament: Address, _match_id: MatchID) -> Result<()> {
            self.record("eliminate_match");
            Ok(())
        }

        async fn eliminate_inner_tournament(
            &self,
            _tournament: Address,
            _inner_tournament: Address,
        ) -> Result<()> {
            self.record("eliminate_child");
            Ok(())
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
    async fn each_prepared_variant_dispatches_exactly_one_mutation() {
        let arena = RecordingArena::default();
        let tournament = address(1);
        let child = address(2);
        let proof = || MerkleProof::leaf(digest(3), U256::ZERO);

        submit_prepared(
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
        assert_eq!(arena.take(), (1, vec!["join"]));

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
            submit_prepared(&arena, action, head()).await.unwrap();
            assert_eq!(arena.take(), (0, vec![expected]));
        }
    }
}
