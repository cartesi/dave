//! Fallible local fulfillment of one pure Hero intent.
//!
//! An intent names where to act. Preparation reads the engaged match from
//! the same immutable context that produced the intent, so a disagreement
//! between them is a node bug and panics. It derives every Merkle opening or
//! machine witness and returns one owned arena action. What it still checks
//! is local material, against itself or against nodes the chain revealed.
//! It performs no provider reads and sends no transaction. The join bond is
//! resolved when the prepared join is submitted.

use alloy::primitives::{Address, U256};
use thiserror::Error;

use crate::{
    engine::{DisputeSource, LevelCoords, RulerFactory},
    merkle::{Digest, MerkleProof},
    tournament::{
        MatchID,
        domain::{
            BisectingMatch, Engagement, LiveMatchState, LocalCommitmentStanding, SemanticSnapshot,
        },
    },
};

use super::{context::HeroContext, planner::HeroIntent};

/// One completely local, owned action ready for the sender boundary.
///
/// `Join` intentionally has no bond field. The executor must resolve the
/// current bond immediately before submission without asking preparation to
/// perform a provider read.
#[allow(clippy::large_enum_variant)]
pub enum PreparedArenaAction {
    Join {
        tournament: Address,
        proof_last: MerkleProof,
        left_child: Digest,
        right_child: Digest,
    },
    ClaimTimeout {
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    },
    Advance {
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    },
    SealLeaf {
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        agree_state_proof: MerkleProof,
    },
    CreateChild {
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        agree_state_proof: MerkleProof,
    },
    ProveLeaf {
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proof: Vec<u8>,
    },
    PropagateChild {
        parent_tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    },
}

#[derive(Debug, Error)]
pub enum PrepareError {
    #[error(
        "{action} root opening hashes to {observed}, not local root {expected}, in tournament {tournament}"
    )]
    RootOpeningMismatch {
        action: &'static str,
        tournament: Address,
        expected: Digest,
        observed: Digest,
    },
    #[error("{action} proof does not open the expected local root in tournament {tournament}")]
    ProofRootMismatch {
        action: &'static str,
        tournament: Address,
    },
    #[error(
        "{action} local node {observed} disagrees with revealing parent {expected} in tournament {tournament}"
    )]
    RevealingParentMismatch {
        action: &'static str,
        tournament: Address,
        expected: Digest,
        observed: Digest,
    },
    #[error("{action} found no divergent branch in tournament {tournament}")]
    NoDivergentBranch {
        action: &'static str,
        tournament: Address,
    },
    #[error("local source failed while preparing {action} in tournament {tournament}: {source}")]
    Source {
        action: &'static str,
        tournament: Address,
        #[source]
        source: anyhow::Error,
    },
}

type PrepareResult<T> = std::result::Result<T, PrepareError>;

/// Fulfill an intent using the same immutable context that produced it.
pub fn prepare<F: RulerFactory>(
    intent: HeroIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    match intent {
        HeroIntent::Join { tournament, .. } => prepare_join(tournament, context, source),
        HeroIntent::ClaimTimeout { tournament } => prepare_timeout(tournament, context, source),
        HeroIntent::Advance { tournament } => prepare_advance(tournament, context, source),
        HeroIntent::SealLeaf { tournament } => {
            let (match_id, left_leaf, right_leaf, agree_state_proof) =
                prepare_seal("seal leaf", tournament, context, source)?;
            Ok(PreparedArenaAction::SealLeaf {
                tournament,
                match_id,
                left_leaf,
                right_leaf,
                agree_state_proof,
            })
        }
        HeroIntent::CreateChild { tournament } => {
            let (match_id, left_leaf, right_leaf, agree_state_proof) =
                prepare_seal("create child", tournament, context, source)?;
            Ok(PreparedArenaAction::CreateChild {
                tournament,
                match_id,
                left_leaf,
                right_leaf,
                agree_state_proof,
            })
        }
        HeroIntent::ProveLeaf { tournament } => prepare_leaf_proof(tournament, context, source),
        HeroIntent::PropagateChild {
            parent_tournament,
            child_tournament,
        } => {
            let (snapshot, coords) = level(context, parent_tournament);
            let (left_node, right_node) = root_children(
                "propagate child",
                parent_tournament,
                coords,
                snapshot.local_commitment(),
                source,
            )?;
            Ok(PreparedArenaAction::PropagateChild {
                parent_tournament,
                child_tournament,
                left_node,
                right_node,
            })
        }
    }
}

fn prepare_join<F: RulerFactory>(
    tournament: Address,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "join";
    let (snapshot, coords) = level(context, tournament);
    let root = snapshot.local_commitment();
    let (left_child, right_child) = root_children(ACTION, tournament, coords, root, source)?;
    let proof_last = source
        .prove_last(coords)
        .map_err(|source| source_error(ACTION, tournament, source))?;
    let expected_position = (U256::from(1) << snapshot.descriptor().height().get()) - U256::ONE;
    if proof_last.position != expected_position || !proof_last.verify_root(root) {
        return Err(PrepareError::ProofRootMismatch {
            action: ACTION,
            tournament,
        });
    }

    Ok(PreparedArenaAction::Join {
        tournament,
        proof_last,
        left_child,
        right_child,
    })
}

fn prepare_timeout<F: RulerFactory>(
    tournament: Address,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    let (snapshot, coords) = level(context, tournament);
    let (left_node, right_node) = root_children(
        "claim timeout",
        tournament,
        coords,
        snapshot.local_commitment(),
        source,
    )?;
    Ok(PreparedArenaAction::ClaimTimeout {
        tournament,
        match_id: engagement(snapshot).match_id(),
        left_node,
        right_node,
    })
}

fn prepare_advance<F: RulerFactory>(
    tournament: Address,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "advance";
    let (snapshot, coords) = level(context, tournament);
    let engagement = engagement(snapshot);
    let LiveMatchState::Bisecting(state) = engagement.live().state() else {
        unreachable!("an advance is planned only on a bisecting match");
    };

    let (left_node, right_node, selected) =
        unresolved_opening(ACTION, tournament, coords, state, source)?;
    let (new_left_node, new_right_node) = source
        .children(&selected)
        .map_err(|source| source_error(ACTION, tournament, source))?;
    require_opening(
        ACTION,
        tournament,
        source
            .node(&selected)
            .map_err(|source| source_error(ACTION, tournament, source))?,
        new_left_node,
        new_right_node,
    )?;

    Ok(PreparedArenaAction::Advance {
        tournament,
        match_id: engagement.match_id(),
        left_node,
        right_node,
        new_left_node,
        new_right_node,
    })
}

/// The leaves under a ready match's contested node and the proof of the last
/// state both sides agree on, shared by leaf sealing and child creation.
fn prepare_seal<F: RulerFactory>(
    action: &'static str,
    tournament: Address,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<(MatchID, Digest, Digest, MerkleProof)> {
    let (snapshot, coords) = level(context, tournament);
    let engagement = engagement(snapshot);
    let (LiveMatchState::ReadyToSealLeaf(state) | LiveMatchState::ReadyToDelegate(state)) =
        engagement.live().state()
    else {
        unreachable!("a seal is planned only on a match ready to seal");
    };

    let contested = coords.node(1, state.coordinate().leaf_position());
    let observed_parent = source
        .node(&contested)
        .map_err(|source| source_error(action, tournament, source))?;
    if observed_parent != state.revealing_parent() {
        return Err(PrepareError::RevealingParentMismatch {
            action,
            tournament,
            expected: state.revealing_parent(),
            observed: observed_parent,
        });
    }
    let (left_leaf, right_leaf) = source
        .children(&contested)
        .map_err(|source| source_error(action, tournament, source))?;
    require_opening(action, tournament, observed_parent, left_leaf, right_leaf)?;

    let waiting = state.waiting_children();
    let left_diverges = left_leaf != waiting.left();
    let divergence_position = if left_diverges {
        state.coordinate().leaf_position()
    } else if right_leaf != waiting.right() {
        state.coordinate().leaf_position() + U256::ONE
    } else {
        return Err(PrepareError::NoDivergentBranch { action, tournament });
    };

    let agree_state_proof = if divergence_position.is_zero() {
        MerkleProof::leaf(snapshot.descriptor().initial_hash(), U256::ZERO)
    } else {
        let agree_position = divergence_position - U256::ONE;
        let proof = source
            .prove_leaf(coords, agree_position)
            .map_err(|source| source_error(action, tournament, source))?;
        let proof_mismatch =
            proof.position != agree_position || !proof.verify_root(snapshot.local_commitment());
        let right_branch_mismatch = !left_diverges && proof.node != left_leaf;
        if proof_mismatch || right_branch_mismatch {
            return Err(PrepareError::ProofRootMismatch { action, tournament });
        }
        proof
    };

    Ok((
        engagement.match_id(),
        left_leaf,
        right_leaf,
        agree_state_proof,
    ))
}

fn prepare_leaf_proof<F: RulerFactory>(
    tournament: Address,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "prove leaf";
    let (snapshot, coords) = level(context, tournament);
    let engagement = engagement(snapshot);
    let LiveMatchState::SealedLeaf(state) = engagement.live().state() else {
        unreachable!("a leaf proof is planned only on a sealed leaf match");
    };

    let (left_node, right_node) = root_children(
        ACTION,
        tournament,
        coords,
        snapshot.local_commitment(),
        source,
    )?;
    let divergence = state.divergence();
    let proof = source
        .prove_transition(
            divergence.coordinate().cycle(),
            divergence.agree_state(),
            divergence.final_state(engagement.local_side()),
        )
        .map_err(|source| source_error(ACTION, tournament, source))?;

    Ok(PreparedArenaAction::ProveLeaf {
        tournament,
        match_id: engagement.match_id(),
        left_node,
        right_node,
        proof,
    })
}

/// The planned level. Assembly builds a snapshot and its coordinates from one
/// descriptor for every tournament on the path, and the intent names one.
fn level(context: &HeroContext, tournament: Address) -> (&SemanticSnapshot, &LevelCoords) {
    let snapshot = context
        .snapshot_at(tournament)
        .expect("an intent names a tournament on the planned path");
    let coords = context
        .coords(&tournament)
        .expect("assembly builds coordinates for every level on the path");
    (snapshot, coords)
}

fn engagement(snapshot: &SemanticSnapshot) -> Engagement {
    let LocalCommitmentStanding::Engaged(engagement) = snapshot.local_standing() else {
        unreachable!("a match action is planned only on an engaged level");
    };
    engagement
}

fn root_children<F: RulerFactory>(
    action: &'static str,
    tournament: Address,
    coords: &LevelCoords,
    root: Digest,
    source: &mut DisputeSource<F>,
) -> PrepareResult<(Digest, Digest)> {
    let (left, right) = source
        .children(&coords.root())
        .map_err(|source| source_error(action, tournament, source))?;
    require_opening(action, tournament, root, left, right)?;
    Ok((left, right))
}

fn unresolved_opening<F: RulerFactory>(
    action: &'static str,
    tournament: Address,
    coords: &LevelCoords,
    state: BisectingMatch,
    source: &mut DisputeSource<F>,
) -> PrepareResult<(Digest, Digest, crate::engine::Quartet)> {
    let contested = coords.node(
        state.remaining_height().get(),
        state.coordinate().leaf_position(),
    );
    let observed_parent = source
        .node(&contested)
        .map_err(|source| source_error(action, tournament, source))?;
    if observed_parent != state.revealing_parent() {
        return Err(PrepareError::RevealingParentMismatch {
            action,
            tournament,
            expected: state.revealing_parent(),
            observed: observed_parent,
        });
    }
    let (left, right) = source
        .children(&contested)
        .map_err(|source| source_error(action, tournament, source))?;
    require_opening(action, tournament, observed_parent, left, right)?;

    let waiting = state.waiting_children();
    let (left_child, right_child) = contested
        .children()
        .expect("validated bisecting match is above leaf height");
    let selected = if left != waiting.left() {
        left_child
    } else if right != waiting.right() {
        right_child
    } else {
        return Err(PrepareError::NoDivergentBranch { action, tournament });
    };
    Ok((left, right, selected))
}

fn require_opening(
    action: &'static str,
    tournament: Address,
    expected: Digest,
    left: Digest,
    right: Digest,
) -> PrepareResult<()> {
    let observed = left.join(&right);
    if observed == expected {
        Ok(())
    } else {
        Err(PrepareError::RootOpeningMismatch {
            action,
            tournament,
            expected,
            observed,
        })
    }
}

fn source_error(action: &'static str, tournament: Address, source: anyhow::Error) -> PrepareError {
    PrepareError::Source {
        action,
        tournament,
        source,
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        engine::{
            spec::{S_SMALL, toy_source},
            toy::{ToyFactory, ToyInput, ToyOutcome, ToyStf},
        },
        tournament::domain::{
            AwaitingChildMatch, BlockDuration, InnerWinner, JoinDisposition, LiveMatch,
            MatchCoordinate, MatchSide, ParentLink, ReadyToSealMatch, SealedDivergence,
            SealedLeafMatch, TimeoutDisposition, TournamentDescriptor, TournamentKind,
            TournamentStanding, WaitingChildren,
        },
    };

    use super::*;
    use crate::hero::planner::{HeroDecision, plan_hero};

    const ROOT: Address = Address::new([0x11; 20]);
    const CHILD: Address = Address::new([0x22; 20]);
    const LEAF: TournamentKind = TournamentKind::Leaf;
    const NON_LEAF: TournamentKind = TournamentKind::NonLeaf;

    #[derive(Clone, Copy)]
    enum Branch {
        Left,
        Right,
        None,
    }

    #[derive(Clone, Copy)]
    enum ProofFault {
        None,
        Agree,
        Post,
    }

    struct Fixture {
        source: DisputeSource<ToyFactory>,
        context: HeroContext,
        descriptor: TournamentDescriptor,
        commitment: Digest,
        match_id: MatchID,
    }

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn script() -> Vec<ToyInput> {
        vec![ToyInput {
            big_cycles: vec![2, 1],
            outcome: ToyOutcome::Accept,
        }]
    }

    fn source() -> DisputeSource<ToyFactory> {
        toy_source(S_SMALL, &script())
    }

    fn descriptor(
        address: Address,
        level: u64,
        kind: TournamentKind,
        initial_hash: Digest,
        base_cycle: U256,
        log2_stride: u64,
        height: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            kind,
            initial_hash,
            base_cycle,
            log2_stride,
            height,
        )
        .unwrap()
    }

    fn single_level_context(
        descriptor: TournamentDescriptor,
        coords: LevelCoords,
        local_commitment: Digest,
        standing: TournamentStanding,
        local_standing: LocalCommitmentStanding,
    ) -> HeroContext {
        let snapshot = SemanticSnapshot::try_new(
            descriptor,
            standing,
            local_commitment,
            local_standing,
            None,
            None,
        )
        .unwrap();
        HeroContext::from_parts(snapshot, [(descriptor.address(), coords)])
    }

    fn id_for(local: Digest, opponent: Digest, side: MatchSide) -> MatchID {
        match side {
            MatchSide::One => MatchID {
                commitment_one: local,
                commitment_two: opponent,
            },
            MatchSide::Two => MatchID {
                commitment_one: opponent,
                commitment_two: local,
            },
        }
    }

    fn waiting(branch: Branch, left: Digest, right: Digest) -> WaitingChildren {
        match branch {
            Branch::Left => WaitingChildren::new(digest(0xe1), right),
            Branch::Right => WaitingChildren::new(left, digest(0xe2)),
            Branch::None => WaitingChildren::new(left, right),
        }
    }

    fn engaged_fixture(
        kind: TournamentKind,
        log2_stride: u64,
        height: u64,
        side: MatchSide,
        build_live: impl FnOnce(
            &mut DisputeSource<ToyFactory>,
            &LevelCoords,
            TournamentDescriptor,
        ) -> LiveMatch,
    ) -> Fixture {
        let mut source = source();
        let initial_hash = ToyStf::hash_of(0);
        let descriptor = descriptor(ROOT, 0, kind, initial_hash, U256::ZERO, log2_stride, height);
        let coords = LevelCoords::new(0, U256::ZERO, log2_stride, height);
        let commitment = source.node(&coords.root()).unwrap();
        let opponent = digest(0xd0);
        assert_ne!(commitment, opponent);
        let match_id = id_for(commitment, opponent, side);
        let live = build_live(&mut source, &coords, descriptor);
        let engagement =
            Engagement::try_new(commitment, match_id, live.state(), live.timeout()).unwrap();
        let context = single_level_context(
            descriptor,
            coords,
            commitment,
            TournamentStanding::MatchesActive {
                joins: JoinDisposition::Closed,
            },
            LocalCommitmentStanding::Engaged(engagement),
        );

        Fixture {
            source,
            context,
            descriptor,
            commitment,
            match_id,
        }
    }

    fn join_fixture() -> Fixture {
        let mut source = source();
        let initial_hash = ToyStf::hash_of(0);
        let descriptor = descriptor(
            ROOT,
            0,
            LEAF,
            initial_hash,
            U256::ZERO,
            0,
            S_SMALL.log2_ruler_span(),
        );
        let coords = LevelCoords::new(0, U256::ZERO, 0, S_SMALL.log2_ruler_span());
        let commitment = source.node(&coords.root()).unwrap();
        let context = single_level_context(
            descriptor,
            coords,
            commitment,
            TournamentStanding::AwaitingClosure,
            LocalCommitmentStanding::NotJoined,
        );
        Fixture {
            source,
            context,
            descriptor,
            commitment,
            match_id: MatchID {
                commitment_one: Digest::ZERO,
                commitment_two: Digest::ZERO,
            },
        }
    }

    fn planned(context: &HeroContext) -> HeroIntent {
        match plan_hero(context.snapshot()) {
            HeroDecision::Act(intent) => intent,
            other => panic!("expected action, got {other:?}"),
        }
    }

    fn live_state(context: &HeroContext) -> LiveMatchState {
        engagement(context.snapshot()).live().state()
    }

    fn advance_fixture(side: MatchSide, branch: Branch) -> Fixture {
        engaged_fixture(LEAF, 0, 7, side, move |source, coords, descriptor| {
            let remaining_height = match side {
                MatchSide::One => 3,
                MatchSide::Two => 2,
            };
            let coordinate = MatchCoordinate::new(U256::ZERO, U256::ZERO);
            let contested = coords.node(remaining_height, coordinate.leaf_position());
            let revealing_parent = source.node(&contested).unwrap();
            let (left, right) = source.children(&contested).unwrap();
            LiveMatch::try_new(
                LiveMatchState::Bisecting(
                    BisectingMatch::try_new(
                        revealing_parent,
                        waiting(branch, left, right),
                        coordinate,
                        remaining_height,
                        side,
                    )
                    .unwrap(),
                ),
                TimeoutDisposition::None,
            )
            .unwrap()
            .validate_in(descriptor)
            .unwrap()
        })
    }

    fn ready_fixture(side: MatchSide, branch: Branch, child: bool) -> Fixture {
        let (kind, log2_stride, height) = if child {
            (NON_LEAF, 3, 4)
        } else {
            match side {
                MatchSide::One => (LEAF, 0, 7),
                MatchSide::Two => (LEAF, 1, 6),
            }
        };
        engaged_fixture(
            kind,
            log2_stride,
            height,
            side,
            move |source, coords, descriptor| {
                let leaf_position = if matches!(branch, Branch::Left) {
                    U256::ZERO
                } else {
                    U256::from(2)
                };
                let cycle = leaf_position << log2_stride;
                let coordinate = MatchCoordinate::new(leaf_position, cycle);
                let contested = coords.node(1, coordinate.leaf_position());
                let revealing_parent = source.node(&contested).unwrap();
                let (left, right) = source.children(&contested).unwrap();
                let ready = ReadyToSealMatch::new(
                    revealing_parent,
                    waiting(branch, left, right),
                    coordinate,
                    side,
                );
                let state = if child {
                    LiveMatchState::ReadyToDelegate(ready)
                } else {
                    LiveMatchState::ReadyToSealLeaf(ready)
                };
                LiveMatch::try_new(state, TimeoutDisposition::None)
                    .unwrap()
                    .validate_in(descriptor)
                    .unwrap()
            },
        )
    }

    fn timeout_fixture(side: MatchSide) -> Fixture {
        engaged_fixture(LEAF, 0, 7, side, move |source, coords, descriptor| {
            let (remaining_height, responder) = match side {
                MatchSide::One => (2, MatchSide::Two),
                MatchSide::Two => (3, MatchSide::One),
            };
            let contested = coords.node(remaining_height, U256::ZERO);
            let revealing_parent = source.node(&contested).unwrap();
            let (left, right) = source.children(&contested).unwrap();
            let state = LiveMatchState::Bisecting(
                BisectingMatch::try_new(
                    revealing_parent,
                    waiting(Branch::Left, left, right),
                    MatchCoordinate::new(U256::ZERO, U256::ZERO),
                    remaining_height,
                    responder,
                )
                .unwrap(),
            );
            let timeout = match side {
                MatchSide::One => TimeoutDisposition::OneWins {
                    deferred_charge: BlockDuration::from_blocks(4),
                },
                MatchSide::Two => TimeoutDisposition::TwoWins {
                    deferred_charge: BlockDuration::from_blocks(4),
                },
            };
            LiveMatch::try_new(state, timeout)
                .unwrap()
                .validate_in(descriptor)
                .unwrap()
        })
    }

    fn proof_fixture(side: MatchSide, fault: ProofFault) -> Fixture {
        engaged_fixture(LEAF, 0, 7, side, move |_source, _coords, descriptor| {
            let position = match side {
                MatchSide::One => U256::ZERO,
                MatchSide::Two => U256::ONE,
            };
            // The script starts with two active usteps, each adding one.
            let before = u64::try_from(position).unwrap();
            let actual_agree = ToyStf::hash_of(before);
            let actual_post = ToyStf::hash_of(before + 1);
            let agree_state = if matches!(fault, ProofFault::Agree) {
                digest(0xc1)
            } else {
                actual_agree
            };
            let local_final = if matches!(fault, ProofFault::Post) {
                digest(0xc2)
            } else {
                actual_post
            };
            let (final_state_one, final_state_two) = match side {
                MatchSide::One => (local_final, digest(0xc3)),
                MatchSide::Two => (digest(0xc4), local_final),
            };
            let sealed = SealedLeafMatch::new(SealedDivergence::new(
                agree_state,
                MatchCoordinate::new(position, position),
                final_state_one,
                final_state_two,
            ));
            LiveMatch::try_new(LiveMatchState::SealedLeaf(sealed), TimeoutDisposition::None)
                .unwrap()
                .validate_in(descriptor)
                .unwrap()
        })
    }

    fn propagation_fixture(side: MatchSide) -> Fixture {
        let mut source = source();
        let root_initial = ToyStf::hash_of(0);
        let parent_descriptor = descriptor(ROOT, 0, NON_LEAF, root_initial, U256::ZERO, 3, 4);
        let parent_coords = LevelCoords::new(0, U256::ZERO, 3, 4);
        let parent_commitment = source.node(&parent_coords.root()).unwrap();
        let opponent = digest(0xb0);
        let parent_match = id_for(parent_commitment, opponent, side);

        let agree_state = root_initial;
        let parent_final = digest(0xb1);
        let opponent_final = digest(0xb2);
        let (final_state_one, final_state_two) = match side {
            MatchSide::One => (parent_final, opponent_final),
            MatchSide::Two => (opponent_final, parent_final),
        };
        let divergence = SealedDivergence::new(
            agree_state,
            MatchCoordinate::new(U256::ZERO, U256::ZERO),
            final_state_one,
            final_state_two,
        );
        let parent_live = LiveMatch::try_new(
            LiveMatchState::AwaitingChild(AwaitingChildMatch::try_new(divergence, CHILD).unwrap()),
            TimeoutDisposition::None,
        )
        .unwrap()
        .validate_in(parent_descriptor)
        .unwrap();

        let child_descriptor = descriptor(CHILD, 1, LEAF, agree_state, U256::ZERO, 0, 3);
        let child_coords = LevelCoords::new(0, U256::ZERO, 0, 3);
        let child_winner = source.node(&child_coords.root()).unwrap();
        let parent_link = ParentLink::try_new(ROOT, parent_match, parent_commitment).unwrap();
        let child_snapshot = SemanticSnapshot::try_new(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(parent_commitment, child_winner)),
            child_winner,
            LocalCommitmentStanding::Candidate,
            Some(parent_link),
            None,
        )
        .unwrap();
        let parent_engagement = Engagement::try_new(
            parent_commitment,
            parent_match,
            parent_live.state(),
            parent_live.timeout(),
        )
        .unwrap();
        let parent_snapshot = SemanticSnapshot::try_new(
            parent_descriptor,
            TournamentStanding::MatchesActive {
                joins: JoinDisposition::Closed,
            },
            parent_commitment,
            LocalCommitmentStanding::Engaged(parent_engagement),
            None,
            Some(child_snapshot),
        )
        .unwrap();
        let context = HeroContext::from_parts(
            parent_snapshot,
            [(ROOT, parent_coords), (CHILD, child_coords)],
        );

        Fixture {
            source,
            context,
            descriptor: parent_descriptor,
            commitment: parent_commitment,
            match_id: parent_match,
        }
    }

    #[test]
    fn join_prepares_root_opening_and_last_proof_without_a_bond_read() {
        let mut fixture = join_fixture();
        let intent = planned(&fixture.context);
        let PreparedArenaAction::Join {
            tournament,
            proof_last,
            left_child,
            right_child,
        } = prepare(intent, &fixture.context, &mut fixture.source).unwrap()
        else {
            panic!("join intent must prepare a join");
        };

        assert_eq!(tournament, ROOT);
        assert_eq!(left_child.join(&right_child), fixture.commitment);
        assert!(proof_last.verify_root(fixture.commitment));
        assert_eq!(
            proof_last.position,
            (U256::ONE << fixture.descriptor.height().get()) - U256::ONE
        );
    }

    #[test]
    fn timeout_prepares_both_match_orientations() {
        for side in [MatchSide::One, MatchSide::Two] {
            let mut fixture = timeout_fixture(side);
            let PreparedArenaAction::ClaimTimeout {
                tournament,
                match_id,
                left_node,
                right_node,
            } = prepare(
                planned(&fixture.context),
                &fixture.context,
                &mut fixture.source,
            )
            .unwrap()
            else {
                panic!("timeout intent must prepare timeout settlement");
            };
            assert_eq!(tournament, ROOT);
            assert_eq!(match_id, fixture.match_id);
            assert_eq!(left_node.join(&right_node), fixture.commitment);
        }
    }

    #[test]
    fn advance_prepares_both_orientations_and_both_branches() {
        for side in [MatchSide::One, MatchSide::Two] {
            for branch in [Branch::Left, Branch::Right] {
                let mut fixture = advance_fixture(side, branch);
                let LiveMatchState::Bisecting(state) = live_state(&fixture.context) else {
                    panic!("advance fixture must be bisecting");
                };
                let waiting = state.waiting_children();
                let PreparedArenaAction::Advance {
                    tournament,
                    match_id,
                    left_node,
                    right_node,
                    new_left_node,
                    new_right_node,
                } = prepare(
                    planned(&fixture.context),
                    &fixture.context,
                    &mut fixture.source,
                )
                .unwrap()
                else {
                    panic!("advance intent must prepare an advance");
                };

                let selected = if left_node != waiting.left() {
                    left_node
                } else {
                    assert_ne!(right_node, waiting.right());
                    right_node
                };
                assert_eq!(tournament, ROOT);
                assert_eq!(match_id, fixture.match_id);
                assert_eq!(left_node.join(&right_node), state.revealing_parent());
                assert_eq!(new_left_node.join(&new_right_node), selected);
            }
        }
    }

    #[test]
    fn leaf_seal_prepares_both_orientations_and_branches_including_zero() {
        for side in [MatchSide::One, MatchSide::Two] {
            for branch in [Branch::Left, Branch::Right] {
                let mut fixture = ready_fixture(side, branch, false);
                let LiveMatchState::ReadyToSealLeaf(state) = live_state(&fixture.context) else {
                    panic!("ready leaf fixture must be ready to seal a leaf");
                };
                let PreparedArenaAction::SealLeaf {
                    tournament,
                    match_id,
                    left_leaf,
                    right_leaf,
                    agree_state_proof,
                } = prepare(
                    planned(&fixture.context),
                    &fixture.context,
                    &mut fixture.source,
                )
                .unwrap()
                else {
                    panic!("seal intent must prepare a leaf seal");
                };

                assert_eq!(tournament, ROOT);
                assert_eq!(match_id, fixture.match_id);
                assert_eq!(left_leaf.join(&right_leaf), state.revealing_parent());
                match branch {
                    Branch::Left => {
                        assert_eq!(agree_state_proof.position, U256::ZERO);
                        assert_eq!(agree_state_proof.node, fixture.descriptor.initial_hash());
                        assert!(agree_state_proof.siblings.is_empty());
                    }
                    Branch::Right => {
                        assert_eq!(
                            agree_state_proof.position,
                            state.coordinate().leaf_position()
                        );
                        assert_eq!(agree_state_proof.node, left_leaf);
                        assert!(agree_state_proof.verify_root(fixture.commitment));
                    }
                    Branch::None => unreachable!(),
                }
            }
        }
    }

    #[test]
    fn child_creation_uses_the_same_exact_nonleaf_seal_material() {
        let mut fixture = ready_fixture(MatchSide::Two, Branch::Right, true);
        let LiveMatchState::ReadyToDelegate(state) = live_state(&fixture.context) else {
            panic!("ready nonleaf fixture must be ready to delegate");
        };
        let PreparedArenaAction::CreateChild {
            tournament,
            match_id,
            left_leaf,
            right_leaf,
            agree_state_proof,
        } = prepare(
            planned(&fixture.context),
            &fixture.context,
            &mut fixture.source,
        )
        .unwrap()
        else {
            panic!("child intent must prepare child creation");
        };

        assert_eq!(tournament, ROOT);
        assert_eq!(match_id, fixture.match_id);
        assert_eq!(left_leaf.join(&right_leaf), state.revealing_parent());
        assert_eq!(
            agree_state_proof.position,
            state.coordinate().leaf_position()
        );
        assert!(agree_state_proof.verify_root(fixture.commitment));
    }

    #[test]
    fn leaf_proof_selects_local_state_and_propagates_source_errors() {
        for side in [MatchSide::One, MatchSide::Two] {
            let mut fixture = proof_fixture(side, ProofFault::None);
            let intent = planned(&fixture.context);
            let PreparedArenaAction::ProveLeaf {
                tournament,
                match_id,
                left_node,
                right_node,
                proof,
            } = prepare(intent, &fixture.context, &mut fixture.source).unwrap()
            else {
                panic!("proof intent must prepare a leaf proof");
            };

            assert_eq!(tournament, ROOT);
            assert_eq!(match_id, fixture.match_id);
            assert_eq!(left_node.join(&right_node), fixture.commitment);
            assert!(!proof.is_empty());
            for (fault, state) in [
                (ProofFault::Agree, "pre-state"),
                (ProofFault::Post, "post-state"),
            ] {
                let mut invalid = proof_fixture(side, fault);
                let Err(PrepareError::Source {
                    action,
                    tournament,
                    source,
                }) = prepare(
                    planned(&invalid.context),
                    &invalid.context,
                    &mut invalid.source,
                )
                else {
                    panic!("invalid {state} must fail proof preparation for {side:?}");
                };
                assert_eq!(action, "prove leaf");
                assert_eq!(tournament, ROOT);
                assert!(source.to_string().contains(state));
            }
        }
    }

    #[test]
    fn child_propagation_prepares_both_parent_orientations() {
        for side in [MatchSide::One, MatchSide::Two] {
            let mut fixture = propagation_fixture(side);
            let PreparedArenaAction::PropagateChild {
                parent_tournament,
                child_tournament,
                left_node,
                right_node,
            } = prepare(
                planned(&fixture.context),
                &fixture.context,
                &mut fixture.source,
            )
            .unwrap()
            else {
                panic!("a finished child must prepare parent settlement");
            };
            assert_eq!(parent_tournament, ROOT);
            assert_eq!(child_tournament, CHILD);
            assert_eq!(left_node.join(&right_node), fixture.commitment);
        }
    }

    #[test]
    fn invalid_local_material_returns_errors_instead_of_prepared_actions() {
        let mut no_divergence = advance_fixture(MatchSide::One, Branch::None);
        assert!(matches!(
            prepare(
                planned(&no_divergence.context),
                &no_divergence.context,
                &mut no_divergence.source
            ),
            Err(PrepareError::NoDivergentBranch {
                action: "advance",
                ..
            })
        ));

        let mut wrong_parent = engaged_fixture(
            LEAF,
            0,
            7,
            MatchSide::One,
            |_source, _coords, descriptor| {
                LiveMatch::try_new(
                    LiveMatchState::Bisecting(
                        BisectingMatch::try_new(
                            digest(0xfb),
                            WaitingChildren::new(digest(0xfc), digest(0xfd)),
                            MatchCoordinate::new(U256::ZERO, U256::ZERO),
                            3,
                            MatchSide::One,
                        )
                        .unwrap(),
                    ),
                    TimeoutDisposition::None,
                )
                .unwrap()
                .validate_in(descriptor)
                .unwrap()
            },
        );
        assert!(matches!(
            prepare(
                planned(&wrong_parent.context),
                &wrong_parent.context,
                &mut wrong_parent.source
            ),
            Err(PrepareError::RevealingParentMismatch {
                action: "advance",
                ..
            })
        ));
    }
}
