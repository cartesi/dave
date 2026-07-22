//! Fallible local fulfillment of one pure Hero intent.
//!
//! Preparation revalidates the intent against the accepted semantic context,
//! derives every Merkle opening or machine witness, and returns one owned arena
//! action. It performs no provider reads and sends no transaction. In
//! particular, the join bond is resolved only when the prepared join is
//! submitted.

use alloy::primitives::{Address, U256};
use thiserror::Error;

use crate::{
    engine::{DisputeSource, RulerFactory, stf::ProvingStf},
    merkle::{Digest, MerkleProof},
    tournament::{
        MatchID,
        domain::{
            BisectingMatch, Engagement, LiveMatchState, LocalCommitmentStanding, MatchSide,
            SemanticSnapshot, TimeoutDisposition, TournamentStanding,
        },
    },
};

use super::{
    context::{HeroContext, LevelMaterial},
    planner::{
        AdvanceIntent, ChildIntent, HeroIntent, JoinIntent, ProofIntent, PropagationIntent,
        SealIntent, TimeoutIntent,
    },
};

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
    #[error("Hero context does not contain tournament {tournament}")]
    MissingSnapshot { tournament: Address },
    #[error("Hero context does not contain local material for tournament {tournament}")]
    MissingLevelMaterial { tournament: Address },
    #[error("semantic and local-material descriptors disagree for tournament {tournament}")]
    LevelDescriptorMismatch { tournament: Address },
    #[error(
        "intent commitment {observed} disagrees with local commitment {expected} in tournament {tournament}"
    )]
    CommitmentMismatch {
        tournament: Address,
        expected: Digest,
        observed: Digest,
    },
    #[error("intent side {side:?} does not own commitment {commitment} in match {match_id_hash}")]
    SideCommitmentMismatch {
        match_id_hash: Digest,
        commitment: Digest,
        side: MatchSide,
    },
    #[error("{action} intent no longer matches the accepted state of tournament {tournament}")]
    IntentStateMismatch {
        action: &'static str,
        tournament: Address,
    },
    #[error("{action} intent carries the wrong match in tournament {tournament}")]
    MatchMismatch {
        action: &'static str,
        tournament: Address,
    },
    #[error("{action} intent carries the wrong local side in tournament {tournament}")]
    SideMismatch {
        action: &'static str,
        tournament: Address,
    },
    #[error("child propagation provenance does not match the accepted context")]
    PropagationProvenanceMismatch,
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
    #[error(
        "positioned machine state {observed} disagrees with sealed agree state {expected} in tournament {tournament}"
    )]
    AgreeStateMismatch {
        tournament: Address,
        expected: Digest,
        observed: Digest,
    },
    #[error(
        "proved post-state {observed} disagrees with side {side:?} final state {expected} in tournament {tournament}"
    )]
    PostStateMismatch {
        tournament: Address,
        side: MatchSide,
        expected: Digest,
        observed: Digest,
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

/// Fulfill exactly one intent from one accepted Hero context.
pub fn prepare<F>(
    intent: HeroIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction>
where
    F: RulerFactory,
    F::S: ProvingStf,
{
    match intent {
        HeroIntent::Join(intent) => prepare_join(intent, context, source),
        HeroIntent::ClaimTimeout(intent) => prepare_timeout(intent, context, source),
        HeroIntent::Advance(intent) => prepare_advance(intent, context, source),
        HeroIntent::SealLeaf(intent) => prepare_seal_leaf(intent, context, source),
        HeroIntent::CreateChild(intent) => prepare_child(intent, context, source),
        HeroIntent::ProveLeaf(intent) => prepare_leaf_proof(intent, context, source),
        HeroIntent::PropagateChild(intent) => prepare_propagation(intent, context, source),
    }
}

fn prepare_join<F: RulerFactory>(
    intent: JoinIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "join";
    let (snapshot, material) = local_level(context, intent.tournament, intent.commitment)?;
    if snapshot.local_standing() != LocalCommitmentStanding::NotJoined
        || !snapshot.standing().accepts_joins()
    {
        return Err(PrepareError::IntentStateMismatch {
            action: ACTION,
            tournament: intent.tournament,
        });
    }

    let (left_child, right_child) = root_children(ACTION, intent.tournament, material, source)?;
    let proof_last = source
        .prove_last(material.coords())
        .map_err(|source| source_error(ACTION, intent.tournament, source))?;
    let expected_position = (U256::from(1) << material.descriptor().height().get()) - U256::ONE;
    if proof_last.position != expected_position || !proof_last.verify_root(material.root()) {
        return Err(PrepareError::ProofRootMismatch {
            action: ACTION,
            tournament: intent.tournament,
        });
    }

    Ok(PreparedArenaAction::Join {
        tournament: intent.tournament,
        proof_last,
        left_child,
        right_child,
    })
}

fn prepare_timeout<F: RulerFactory>(
    intent: TimeoutIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "claim timeout";
    let (snapshot, material) = local_level(context, intent.tournament, intent.commitment)?;
    let engagement = validate_engagement(
        ACTION,
        intent.tournament,
        snapshot,
        intent.match_id,
        intent.commitment,
        intent.survivor,
    )?;
    if engagement.live().timeout().winner() != Some((intent.survivor, intent.deferred_charge)) {
        return Err(PrepareError::IntentStateMismatch {
            action: ACTION,
            tournament: intent.tournament,
        });
    }

    let (left_node, right_node) = root_children(ACTION, intent.tournament, material, source)?;
    Ok(PreparedArenaAction::ClaimTimeout {
        tournament: intent.tournament,
        match_id: intent.match_id,
        left_node,
        right_node,
    })
}

fn prepare_advance<F: RulerFactory>(
    intent: AdvanceIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "advance";
    let (snapshot, material) = local_level(context, intent.tournament, intent.commitment)?;
    let engagement = validate_engagement(
        ACTION,
        intent.tournament,
        snapshot,
        intent.match_id,
        intent.commitment,
        intent.side,
    )?;
    if engagement.live().timeout() != TimeoutDisposition::None
        || engagement.live().state() != LiveMatchState::Bisecting(intent.match_state)
        || intent.match_state.responder() != intent.side
    {
        return Err(PrepareError::IntentStateMismatch {
            action: ACTION,
            tournament: intent.tournament,
        });
    }

    let (left_node, right_node, selected) = unresolved_opening(
        ACTION,
        intent.tournament,
        material,
        intent.match_state,
        source,
    )?;
    let (new_left_node, new_right_node) = source
        .children(&selected)
        .map_err(|source| source_error(ACTION, intent.tournament, source))?;
    require_opening(
        ACTION,
        intent.tournament,
        source
            .node(&selected)
            .map_err(|source| source_error(ACTION, intent.tournament, source))?,
        new_left_node,
        new_right_node,
    )?;

    Ok(PreparedArenaAction::Advance {
        tournament: intent.tournament,
        match_id: intent.match_id,
        left_node,
        right_node,
        new_left_node,
        new_right_node,
    })
}

fn prepare_seal_leaf<F: RulerFactory>(
    intent: SealIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "seal leaf";
    let (left_leaf, right_leaf, agree_state_proof) =
        prepare_seal_material(ACTION, &intent, context, source, false)?;
    Ok(PreparedArenaAction::SealLeaf {
        tournament: intent.tournament,
        match_id: intent.match_id,
        left_leaf,
        right_leaf,
        agree_state_proof,
    })
}

fn prepare_child<F: RulerFactory>(
    intent: ChildIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "create child";
    let seal = SealIntent {
        tournament: intent.tournament,
        match_id: intent.match_id,
        commitment: intent.commitment,
        side: intent.side,
        match_state: intent.match_state,
    };
    let (left_leaf, right_leaf, agree_state_proof) =
        prepare_seal_material(ACTION, &seal, context, source, true)?;
    Ok(PreparedArenaAction::CreateChild {
        tournament: intent.tournament,
        match_id: intent.match_id,
        left_leaf,
        right_leaf,
        agree_state_proof,
    })
}

fn prepare_seal_material<F: RulerFactory>(
    action: &'static str,
    intent: &SealIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
    child: bool,
) -> PrepareResult<(Digest, Digest, MerkleProof)> {
    let (snapshot, material) = local_level(context, intent.tournament, intent.commitment)?;
    let engagement = validate_engagement(
        action,
        intent.tournament,
        snapshot,
        intent.match_id,
        intent.commitment,
        intent.side,
    )?;
    let expected_state = if child {
        LiveMatchState::ReadyToDelegate(intent.match_state)
    } else {
        LiveMatchState::ReadyToSealLeaf(intent.match_state)
    };
    if engagement.live().timeout() != TimeoutDisposition::None
        || engagement.live().state() != expected_state
        || intent.match_state.responder() != intent.side
    {
        return Err(PrepareError::IntentStateMismatch {
            action,
            tournament: intent.tournament,
        });
    }

    let contested = material
        .coords()
        .node(1, intent.match_state.coordinate().leaf_position());
    let observed_parent = source
        .node(&contested)
        .map_err(|source| source_error(action, intent.tournament, source))?;
    if observed_parent != intent.match_state.revealing_parent() {
        return Err(PrepareError::RevealingParentMismatch {
            action,
            tournament: intent.tournament,
            expected: intent.match_state.revealing_parent(),
            observed: observed_parent,
        });
    }
    let (left_leaf, right_leaf) = source
        .children(&contested)
        .map_err(|source| source_error(action, intent.tournament, source))?;
    require_opening(
        action,
        intent.tournament,
        observed_parent,
        left_leaf,
        right_leaf,
    )?;

    let waiting = intent.match_state.waiting_children();
    let left_diverges = left_leaf != waiting.left();
    let divergence_position = if left_diverges {
        intent.match_state.coordinate().leaf_position()
    } else if right_leaf != waiting.right() {
        intent.match_state.coordinate().leaf_position() + U256::ONE
    } else {
        return Err(PrepareError::NoDivergentBranch {
            action,
            tournament: intent.tournament,
        });
    };

    let agree_state_proof = if divergence_position.is_zero() {
        MerkleProof::leaf(material.descriptor().initial_hash(), U256::ZERO)
    } else {
        source
            .prove_leaf(material.coords(), divergence_position - U256::ONE)
            .map_err(|source| source_error(action, intent.tournament, source))?
    };
    if divergence_position.is_zero() {
        if agree_state_proof.node != material.descriptor().initial_hash()
            || !agree_state_proof.siblings.is_empty()
        {
            return Err(PrepareError::ProofRootMismatch {
                action,
                tournament: intent.tournament,
            });
        }
    } else {
        let proof_mismatch = agree_state_proof.position != divergence_position - U256::ONE
            || !agree_state_proof.verify_root(material.root());
        let right_branch_mismatch = !left_diverges && agree_state_proof.node != left_leaf;
        if proof_mismatch || right_branch_mismatch {
            return Err(PrepareError::ProofRootMismatch {
                action,
                tournament: intent.tournament,
            });
        }
    }

    Ok((left_leaf, right_leaf, agree_state_proof))
}

fn prepare_leaf_proof<F>(
    intent: ProofIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction>
where
    F: RulerFactory,
    F::S: ProvingStf,
{
    const ACTION: &str = "prove leaf";
    let (snapshot, material) = local_level(context, intent.tournament, intent.commitment)?;
    let engagement = validate_engagement(
        ACTION,
        intent.tournament,
        snapshot,
        intent.match_id,
        intent.commitment,
        intent.side,
    )?;
    if engagement.live().timeout() != TimeoutDisposition::None
        || engagement.live().state() != LiveMatchState::SealedLeaf(intent.match_state)
    {
        return Err(PrepareError::IntentStateMismatch {
            action: ACTION,
            tournament: intent.tournament,
        });
    }

    let (left_node, right_node) = root_children(ACTION, intent.tournament, material, source)?;
    let divergence = intent.match_state.divergence();
    let mut ruler = source
        .machine_at(divergence.coordinate().cycle())
        .map_err(|source| source_error(ACTION, intent.tournament, source))?;
    let agree_state = ruler
        .state_hash()
        .map_err(|source| source_error(ACTION, intent.tournament, source))?;
    if agree_state != divergence.agree_state() {
        return Err(PrepareError::AgreeStateMismatch {
            tournament: intent.tournament,
            expected: divergence.agree_state(),
            observed: agree_state,
        });
    }

    let (proof, post_state) = ruler
        .prove_transition()
        .map_err(|source| source_error(ACTION, intent.tournament, source))?;
    let expected_post_state = divergence.final_state(intent.side);
    if post_state != expected_post_state {
        return Err(PrepareError::PostStateMismatch {
            tournament: intent.tournament,
            side: intent.side,
            expected: expected_post_state,
            observed: post_state,
        });
    }

    Ok(PreparedArenaAction::ProveLeaf {
        tournament: intent.tournament,
        match_id: intent.match_id,
        left_node,
        right_node,
        proof,
    })
}

fn prepare_propagation<F: RulerFactory>(
    intent: PropagationIntent,
    context: &HeroContext,
    source: &mut DisputeSource<F>,
) -> PrepareResult<PreparedArenaAction> {
    const ACTION: &str = "propagate child";
    let child_snapshot =
        context
            .snapshot_at(intent.child_tournament)
            .ok_or(PrepareError::MissingSnapshot {
                tournament: intent.child_tournament,
            })?;
    let (parent_snapshot, parent_material) =
        local_level(context, intent.parent_tournament, intent.parent_commitment)?;

    let parent_link = child_snapshot
        .parent()
        .ok_or(PrepareError::PropagationProvenanceMismatch)?;
    let winner = match child_snapshot.standing() {
        TournamentStanding::InnerWinner(winner) => winner,
        _ => return Err(PrepareError::PropagationProvenanceMismatch),
    };
    let parent_engagement = match parent_snapshot.local_standing() {
        LocalCommitmentStanding::Engaged(engagement) => engagement,
        _ => return Err(PrepareError::PropagationProvenanceMismatch),
    };
    let child_address = match parent_engagement.live().state() {
        LiveMatchState::AwaitingChild(awaiting) => awaiting.child_tournament(),
        _ => return Err(PrepareError::PropagationProvenanceMismatch),
    };
    let retained_child = parent_snapshot
        .child()
        .map(|child| child.descriptor().address());

    if parent_link.parent_tournament() != intent.parent_tournament
        || parent_link.parent_match() != intent.parent_match
        || parent_link.parent_commitment() != intent.parent_commitment
        || parent_link.parent_side() != intent.parent_side
        || winner.parent_commitment() != intent.parent_commitment
        || winner.child_commitment() != intent.child_winner
        || parent_engagement.match_id() != intent.parent_match
        || parent_engagement.local_side() != intent.parent_side
        || intent.parent_side.commitment(intent.parent_match) != intent.parent_commitment
        || child_address != intent.child_tournament
        || retained_child != Some(intent.child_tournament)
    {
        return Err(PrepareError::PropagationProvenanceMismatch);
    }

    let (left_node, right_node) =
        root_children(ACTION, intent.parent_tournament, parent_material, source)?;
    Ok(PreparedArenaAction::PropagateChild {
        parent_tournament: intent.parent_tournament,
        child_tournament: intent.child_tournament,
        left_node,
        right_node,
    })
}

fn local_level(
    context: &HeroContext,
    tournament: Address,
    commitment: Digest,
) -> PrepareResult<(&SemanticSnapshot, &LevelMaterial)> {
    let snapshot = context
        .snapshot_at(tournament)
        .ok_or(PrepareError::MissingSnapshot { tournament })?;
    let material = context
        .level(&tournament)
        .ok_or(PrepareError::MissingLevelMaterial { tournament })?;
    if snapshot.descriptor() != material.descriptor()
        || snapshot.descriptor().address() != tournament
    {
        return Err(PrepareError::LevelDescriptorMismatch { tournament });
    }
    let expected = snapshot.local_commitment();
    if material.root() != expected || commitment != expected {
        return Err(PrepareError::CommitmentMismatch {
            tournament,
            expected,
            observed: commitment,
        });
    }
    Ok((snapshot, material))
}

fn validate_engagement(
    action: &'static str,
    tournament: Address,
    snapshot: &SemanticSnapshot,
    match_id: MatchID,
    commitment: Digest,
    side: MatchSide,
) -> PrepareResult<Engagement> {
    if side.commitment(match_id) != commitment {
        return Err(PrepareError::SideCommitmentMismatch {
            match_id_hash: match_id.hash(),
            commitment,
            side,
        });
    }
    let engagement = match snapshot.local_standing() {
        LocalCommitmentStanding::Engaged(engagement) => engagement,
        _ => return Err(PrepareError::IntentStateMismatch { action, tournament }),
    };
    if engagement.match_id() != match_id {
        return Err(PrepareError::MatchMismatch { action, tournament });
    }
    if engagement.local_side() != side {
        return Err(PrepareError::SideMismatch { action, tournament });
    }
    Ok(engagement)
}

fn root_children<F: RulerFactory>(
    action: &'static str,
    tournament: Address,
    material: &LevelMaterial,
    source: &mut DisputeSource<F>,
) -> PrepareResult<(Digest, Digest)> {
    let (left, right) = source
        .children(&material.coords().root())
        .map_err(|source| source_error(action, tournament, source))?;
    require_opening(action, tournament, material.root(), left, right)?;
    Ok((left, right))
}

fn unresolved_opening<F: RulerFactory>(
    action: &'static str,
    tournament: Address,
    material: &LevelMaterial,
    state: BisectingMatch,
    source: &mut DisputeSource<F>,
) -> PrepareResult<(Digest, Digest, crate::engine::Quartet)> {
    let contested = material.coords().node(
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
    use std::collections::HashMap;

    use crate::{
        engine::{
            LevelCoords, ToyFactory, ToyInput, ToyOutcome,
            spec::{S_SMALL, toy_source},
        },
        tournament::{
            adapter::{ObservedMatch, TournamentObservation},
            domain::{
                AwaitingChildMatch, BlockDuration, InnerWinner, JoinDisposition, LiveMatch,
                MatchCoordinate, ReadyToSealMatch, SealedDivergence, SealedLeafMatch,
                TournamentDescriptor, WaitingChildren,
            },
            fold::{EventKind, Fold, TournamentEvent},
        },
    };

    use super::*;
    use crate::hero::planner::{HeroDecision, plan_hero};

    const ROOT: Address = Address::new([0x11; 20]);
    const CHILD: Address = Address::new([0x22; 20]);

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

    fn initial_hash(source: &mut DisputeSource<ToyFactory>) -> Digest {
        source.machine_at(U256::ZERO).unwrap().state_hash().unwrap()
    }

    fn descriptor(
        address: Address,
        level: u64,
        levels: u64,
        initial_hash: Digest,
        base_cycle: U256,
        log2_stride: u64,
        height: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            levels,
            initial_hash,
            base_cycle,
            log2_stride,
            height,
        )
        .unwrap()
    }

    fn event(tournament: Address, block: u64, kind: EventKind) -> TournamentEvent {
        TournamentEvent {
            tournament,
            block,
            kind,
        }
    }

    fn observation(
        descriptor: TournamentDescriptor,
        standing: TournamentStanding,
        matches: impl IntoIterator<Item = (MatchID, LiveMatch)>,
    ) -> TournamentObservation {
        TournamentObservation::from_parts(
            descriptor,
            standing,
            matches
                .into_iter()
                .map(|(id, live)| (id.hash(), ObservedMatch::from_parts(id, live)))
                .collect(),
        )
    }

    fn apply(fold: &mut Fold, tournament: Address, block: u64, kind: EventKind) {
        fold.apply(&event(tournament, block, kind)).unwrap();
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
        levels: u64,
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
        let initial_hash = initial_hash(&mut source);
        let descriptor = descriptor(
            ROOT,
            0,
            levels,
            initial_hash,
            U256::ZERO,
            log2_stride,
            height,
        );
        let coords = LevelCoords::new(0, U256::ZERO, log2_stride, height);
        let commitment = source.node(&coords.root()).unwrap();
        let final_state = source.prove_last(&coords).unwrap().node;
        let opponent = digest(0xd0);
        assert_ne!(commitment, opponent);
        let match_id = id_for(commitment, opponent, side);
        let live = build_live(&mut source, &coords, descriptor);

        let final_state_one = if side == MatchSide::One {
            final_state
        } else {
            digest(0xd1)
        };
        let final_state_two = if side == MatchSide::Two {
            final_state
        } else {
            digest(0xd2)
        };
        let mut fold = Fold::new(ROOT);
        apply(
            &mut fold,
            ROOT,
            1,
            EventKind::CommitmentJoined {
                root: match_id.commitment_one,
                final_state: final_state_one,
            },
        );
        apply(
            &mut fold,
            ROOT,
            2,
            EventKind::CommitmentJoined {
                root: match_id.commitment_two,
                final_state: final_state_two,
            },
        );
        apply(
            &mut fold,
            ROOT,
            3,
            EventKind::MatchCreated {
                one: match_id.commitment_one,
                two: match_id.commitment_two,
                left_of_two: digest(0xd3),
            },
        );
        let observations = HashMap::from([(
            ROOT,
            observation(
                descriptor,
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins: JoinDisposition::Closed,
                },
                [(match_id, live)],
            ),
        )]);
        let context =
            HeroContext::assemble(0, initial_hash, &fold, &observations, &mut source).unwrap();

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
        let initial_hash = initial_hash(&mut source);
        let descriptor = descriptor(
            ROOT,
            0,
            1,
            initial_hash,
            U256::ZERO,
            0,
            S_SMALL.log2_ruler_span(),
        );
        let coords = LevelCoords::new(0, U256::ZERO, 0, S_SMALL.log2_ruler_span());
        let commitment = source.node(&coords.root()).unwrap();
        let fold = Fold::new(ROOT);
        let observations = HashMap::from([(
            ROOT,
            observation(
                descriptor,
                TournamentStanding::AwaitingClosure { candidate: None },
                [],
            ),
        )]);
        let context =
            HeroContext::assemble(0, initial_hash, &fold, &observations, &mut source).unwrap();
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

    fn advance_fixture(side: MatchSide, branch: Branch) -> Fixture {
        engaged_fixture(1, 0, 7, side, move |source, coords, descriptor| {
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
        let (levels, log2_stride, height) = if child {
            (2, 3, 4)
        } else {
            match side {
                MatchSide::One => (1, 0, 7),
                MatchSide::Two => (1, 1, 6),
            }
        };
        engaged_fixture(
            levels,
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
        engaged_fixture(1, 0, 7, side, move |source, coords, descriptor| {
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
        engaged_fixture(1, 0, 7, side, move |source, _coords, descriptor| {
            let position = match side {
                MatchSide::One => U256::ZERO,
                MatchSide::Two => U256::ONE,
            };
            let mut ruler = source.machine_at(position).unwrap();
            let actual_agree = ruler.state_hash().unwrap();
            let (_, actual_post) = ruler.prove_transition().unwrap();
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
        let root_initial = initial_hash(&mut source);
        let parent_descriptor = descriptor(ROOT, 0, 2, root_initial, U256::ZERO, 3, 4);
        let parent_coords = LevelCoords::new(0, U256::ZERO, 3, 4);
        let parent_commitment = source.node(&parent_coords.root()).unwrap();
        let opponent = digest(0xb0);
        let parent_match = id_for(parent_commitment, opponent, side);

        let mut ruler = source.machine_at(U256::ZERO).unwrap();
        let agree_state = ruler.state_hash().unwrap();
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

        let child_descriptor = descriptor(CHILD, 1, 2, agree_state, U256::ZERO, 0, 3);
        let child_coords = LevelCoords::new(0, U256::ZERO, 0, 3);
        let child_winner = source.node(&child_coords.root()).unwrap();

        let mut fold = Fold::new(ROOT);
        apply(
            &mut fold,
            ROOT,
            1,
            EventKind::CommitmentJoined {
                root: parent_match.commitment_one,
                final_state: final_state_one,
            },
        );
        apply(
            &mut fold,
            ROOT,
            2,
            EventKind::CommitmentJoined {
                root: parent_match.commitment_two,
                final_state: final_state_two,
            },
        );
        apply(
            &mut fold,
            ROOT,
            3,
            EventKind::MatchCreated {
                one: parent_match.commitment_one,
                two: parent_match.commitment_two,
                left_of_two: digest(0xb3),
            },
        );
        apply(
            &mut fold,
            ROOT,
            4,
            EventKind::NewInnerTournament {
                match_id_hash: parent_match.hash(),
                child: CHILD,
            },
        );
        apply(
            &mut fold,
            CHILD,
            5,
            EventKind::CommitmentJoined {
                root: child_winner,
                final_state: parent_final,
            },
        );

        let observations = HashMap::from([
            (
                ROOT,
                observation(
                    parent_descriptor,
                    TournamentStanding::MatchesActive {
                        candidate: None,
                        joins: JoinDisposition::Closed,
                    },
                    [(parent_match, parent_live)],
                ),
            ),
            (
                CHILD,
                observation(
                    child_descriptor,
                    TournamentStanding::InnerWinner(InnerWinner::new(
                        parent_commitment,
                        child_winner,
                    )),
                    [],
                ),
            ),
        ]);
        let context =
            HeroContext::assemble(0, root_initial, &fold, &observations, &mut source).unwrap();

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
    fn timeout_revalidates_both_match_orientations_and_exact_charge() {
        for side in [MatchSide::One, MatchSide::Two] {
            let mut fixture = timeout_fixture(side);
            let intent = planned(&fixture.context);
            let HeroIntent::ClaimTimeout(mut stale) = intent else {
                panic!("timeout fixture must plan timeout");
            };
            stale.deferred_charge = BlockDuration::from_blocks(5);
            assert!(matches!(
                prepare(
                    HeroIntent::ClaimTimeout(stale),
                    &fixture.context,
                    &mut fixture.source
                ),
                Err(PrepareError::IntentStateMismatch {
                    action: "claim timeout",
                    ..
                })
            ));

            let PreparedArenaAction::ClaimTimeout {
                tournament,
                match_id,
                left_node,
                right_node,
            } = prepare(intent, &fixture.context, &mut fixture.source).unwrap()
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
                let HeroIntent::Advance(intent) = planned(&fixture.context) else {
                    panic!("advance fixture must plan an advance");
                };
                let state = intent.match_state;
                let waiting = state.waiting_children();
                let PreparedArenaAction::Advance {
                    tournament,
                    match_id,
                    left_node,
                    right_node,
                    new_left_node,
                    new_right_node,
                } = prepare(
                    HeroIntent::Advance(intent),
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
                let HeroIntent::SealLeaf(intent) = planned(&fixture.context) else {
                    panic!("ready leaf fixture must plan a seal");
                };
                let PreparedArenaAction::SealLeaf {
                    tournament,
                    match_id,
                    left_leaf,
                    right_leaf,
                    agree_state_proof,
                } = prepare(
                    HeroIntent::SealLeaf(intent),
                    &fixture.context,
                    &mut fixture.source,
                )
                .unwrap()
                else {
                    panic!("seal intent must prepare a leaf seal");
                };

                assert_eq!(tournament, ROOT);
                assert_eq!(match_id, fixture.match_id);
                assert_eq!(
                    left_leaf.join(&right_leaf),
                    intent.match_state.revealing_parent()
                );
                match branch {
                    Branch::Left => {
                        assert_eq!(agree_state_proof.position, U256::ZERO);
                        assert_eq!(agree_state_proof.node, fixture.descriptor.initial_hash());
                        assert!(agree_state_proof.siblings.is_empty());
                    }
                    Branch::Right => {
                        assert_eq!(
                            agree_state_proof.position,
                            intent.match_state.coordinate().leaf_position()
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
        let HeroIntent::CreateChild(intent) = planned(&fixture.context) else {
            panic!("ready nonleaf fixture must plan child creation");
        };
        let PreparedArenaAction::CreateChild {
            tournament,
            match_id,
            left_leaf,
            right_leaf,
            agree_state_proof,
        } = prepare(
            HeroIntent::CreateChild(intent),
            &fixture.context,
            &mut fixture.source,
        )
        .unwrap()
        else {
            panic!("child intent must prepare child creation");
        };

        assert_eq!(tournament, ROOT);
        assert_eq!(match_id, fixture.match_id);
        assert_eq!(
            left_leaf.join(&right_leaf),
            intent.match_state.revealing_parent()
        );
        assert_eq!(
            agree_state_proof.position,
            intent.match_state.coordinate().leaf_position()
        );
        assert!(agree_state_proof.verify_root(fixture.commitment));
    }

    #[test]
    fn leaf_proof_checks_agree_and_post_state_in_both_orientations() {
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
        }

        let mut wrong_agree = proof_fixture(MatchSide::One, ProofFault::Agree);
        assert!(matches!(
            prepare(
                planned(&wrong_agree.context),
                &wrong_agree.context,
                &mut wrong_agree.source
            ),
            Err(PrepareError::AgreeStateMismatch { .. })
        ));

        let mut wrong_post = proof_fixture(MatchSide::Two, ProofFault::Post);
        assert!(matches!(
            prepare(
                planned(&wrong_post.context),
                &wrong_post.context,
                &mut wrong_post.source
            ),
            Err(PrepareError::PostStateMismatch {
                side: MatchSide::Two,
                ..
            })
        ));
    }

    #[test]
    fn child_propagation_revalidates_both_parent_orientations() {
        for side in [MatchSide::One, MatchSide::Two] {
            let mut fixture = propagation_fixture(side);
            let HeroIntent::PropagateChild(intent) = planned(&fixture.context) else {
                panic!("finished child must plan propagation");
            };
            let PreparedArenaAction::PropagateChild {
                parent_tournament,
                child_tournament,
                left_node,
                right_node,
            } = prepare(
                HeroIntent::PropagateChild(intent),
                &fixture.context,
                &mut fixture.source,
            )
            .unwrap()
            else {
                panic!("propagation intent must prepare parent settlement");
            };
            assert_eq!(parent_tournament, ROOT);
            assert_eq!(child_tournament, CHILD);
            assert_eq!(left_node.join(&right_node), fixture.commitment);

            let mut stale = intent;
            stale.child_winner = digest(0xfa);
            assert!(matches!(
                prepare(
                    HeroIntent::PropagateChild(stale),
                    &fixture.context,
                    &mut fixture.source
                ),
                Err(PrepareError::PropagationProvenanceMismatch)
            ));
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

        let mut wrong_parent =
            engaged_fixture(1, 0, 7, MatchSide::One, |_source, _coords, descriptor| {
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
            });
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

        let mut join = join_fixture();
        let HeroIntent::Join(mut wrong_commitment) = planned(&join.context) else {
            panic!("join fixture must plan join");
        };
        wrong_commitment.commitment = digest(0xfe);
        assert!(matches!(
            prepare(
                HeroIntent::Join(wrong_commitment),
                &join.context,
                &mut join.source
            ),
            Err(PrepareError::CommitmentMismatch { .. })
        ));
    }
}
