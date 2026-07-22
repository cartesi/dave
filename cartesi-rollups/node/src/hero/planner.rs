//! Pure Hero policy over the semantic tournament domain.
//!
//! Planning chooses one terminal, wait, or action decision. It performs no
//! provider calls, constructs no Merkle material, and owns no transaction
//! sender. The production actor invokes it only after assembling a validated
//! snapshot.

use alloy::primitives::Address;

use crate::{
    merkle::Digest,
    tournament::{
        MatchID,
        domain::{
            BisectingMatch, BlockDuration, Engagement, InnerEliminationReason, LiveMatchState,
            MatchSide, ParentLink, ReadyToSealMatch, SealedLeafMatch, SemanticSnapshot,
            TimeoutDisposition, TournamentStanding,
        },
    },
};

/// The complete result of planning one accepted observation.
// Decisions are short-lived values; keeping action payloads inline preserves a
// simple value API at the planner/executor boundary.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeroDecision {
    Terminal(HeroTerminal),
    Wait(WaitReason),
    Act(HeroIntent),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeroTerminal {
    Won,
    Lost,
    FailedNoWinner,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaitReason {
    CandidateBlockedByMatches,
    AwaitingTournamentClosure,
    JoinsClosed,
    OpponentTurn { responder: MatchSide },
    OpponentWinsByTimeout { winner: MatchSide },
    MatchEliminable,
    ChildEliminable { reason: InnerEliminationReason },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeroIntent {
    Join(JoinIntent),
    ClaimTimeout(TimeoutIntent),
    Advance(AdvanceIntent),
    SealLeaf(SealIntent),
    CreateChild(ChildIntent),
    ProveLeaf(ProofIntent),
    PropagateChild(PropagationIntent),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct JoinIntent {
    pub tournament: Address,
    pub commitment: Digest,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimeoutIntent {
    pub tournament: Address,
    pub match_id: MatchID,
    pub commitment: Digest,
    pub survivor: MatchSide,
    pub deferred_charge: BlockDuration,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AdvanceIntent {
    pub tournament: Address,
    pub match_id: MatchID,
    pub commitment: Digest,
    pub side: MatchSide,
    pub match_state: BisectingMatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SealIntent {
    pub tournament: Address,
    pub match_id: MatchID,
    pub commitment: Digest,
    pub side: MatchSide,
    pub match_state: ReadyToSealMatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChildIntent {
    pub tournament: Address,
    pub match_id: MatchID,
    pub commitment: Digest,
    pub side: MatchSide,
    pub match_state: ReadyToSealMatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProofIntent {
    pub tournament: Address,
    pub match_id: MatchID,
    pub commitment: Digest,
    pub side: MatchSide,
    pub match_state: SealedLeafMatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PropagationIntent {
    pub parent_tournament: Address,
    pub child_tournament: Address,
    pub parent_match: MatchID,
    pub parent_commitment: Digest,
    pub parent_side: MatchSide,
    pub child_winner: Digest,
}

/// Choose exactly one decision for a semantic snapshot.
///
/// The first applicable category wins: terminal result, child propagation,
/// join, timeout, then structural match phase. Awaiting a child recursively
/// returns that child's one decision; it is not an action by itself.
pub fn plan_hero(snapshot: &SemanticSnapshot) -> HeroDecision {
    match snapshot.standing() {
        TournamentStanding::RootWinner(winner) => {
            if winner.commitment() == snapshot.local_commitment() {
                return HeroDecision::Terminal(HeroTerminal::Won);
            }
            return HeroDecision::Terminal(HeroTerminal::Lost);
        }
        TournamentStanding::RootFailed => {
            return HeroDecision::Terminal(HeroTerminal::FailedNoWinner);
        }
        TournamentStanding::InnerWinner(winner) => {
            let parent = snapshot
                .parent()
                .expect("validated inner snapshots carry a parent link");
            if winner.parent_commitment() != parent.parent_commitment() {
                return HeroDecision::Terminal(HeroTerminal::Lost);
            }
            return HeroDecision::Act(HeroIntent::PropagateChild(propagation_intent(
                snapshot,
                parent,
                winner.child_commitment(),
            )));
        }
        TournamentStanding::InnerEliminable { reason } => {
            return HeroDecision::Wait(WaitReason::ChildEliminable { reason });
        }
        TournamentStanding::MatchesActive { .. } | TournamentStanding::AwaitingClosure { .. } => {}
    }

    match snapshot.local_standing() {
        crate::tournament::domain::LocalCommitmentStanding::NotJoined => {
            if snapshot.standing().accepts_joins() {
                HeroDecision::Act(HeroIntent::Join(JoinIntent {
                    tournament: snapshot.descriptor().address(),
                    commitment: snapshot.local_commitment(),
                }))
            } else {
                HeroDecision::Wait(WaitReason::JoinsClosed)
            }
        }
        crate::tournament::domain::LocalCommitmentStanding::Candidate => {
            match snapshot.standing() {
                TournamentStanding::MatchesActive { .. } => {
                    HeroDecision::Wait(WaitReason::CandidateBlockedByMatches)
                }
                TournamentStanding::AwaitingClosure { .. } => {
                    HeroDecision::Wait(WaitReason::AwaitingTournamentClosure)
                }
                _ => unreachable!("terminal standings returned before local planning"),
            }
        }
        crate::tournament::domain::LocalCommitmentStanding::Eliminated(_) => {
            HeroDecision::Terminal(HeroTerminal::Lost)
        }
        crate::tournament::domain::LocalCommitmentStanding::Engaged(engagement) => {
            plan_engagement(snapshot, engagement)
        }
    }
}

fn propagation_intent(
    snapshot: &SemanticSnapshot,
    parent: ParentLink,
    child_winner: Digest,
) -> PropagationIntent {
    PropagationIntent {
        parent_tournament: parent.parent_tournament(),
        child_tournament: snapshot.descriptor().address(),
        parent_match: parent.parent_match(),
        parent_commitment: parent.parent_commitment(),
        parent_side: parent.parent_side(),
        child_winner,
    }
}

fn plan_engagement(snapshot: &SemanticSnapshot, engagement: Engagement) -> HeroDecision {
    match engagement.live().timeout() {
        TimeoutDisposition::OneWins { deferred_charge } => {
            return plan_timeout_winner(snapshot, engagement, MatchSide::One, deferred_charge);
        }
        TimeoutDisposition::TwoWins { deferred_charge } => {
            return plan_timeout_winner(snapshot, engagement, MatchSide::Two, deferred_charge);
        }
        TimeoutDisposition::EliminateBoth => {
            return HeroDecision::Wait(WaitReason::MatchEliminable);
        }
        TimeoutDisposition::None => {}
    }

    let tournament = snapshot.descriptor().address();
    let commitment = snapshot.local_commitment();
    let match_id = engagement.match_id();
    let side = engagement.local_side();

    match engagement.live().state() {
        LiveMatchState::Bisecting(match_state) => {
            plan_responder(match_state.responder(), side, || {
                HeroIntent::Advance(AdvanceIntent {
                    tournament,
                    match_id,
                    commitment,
                    side,
                    match_state,
                })
            })
        }
        LiveMatchState::ReadyToSealLeaf(match_state) => {
            plan_responder(match_state.responder(), side, || {
                HeroIntent::SealLeaf(SealIntent {
                    tournament,
                    match_id,
                    commitment,
                    side,
                    match_state,
                })
            })
        }
        LiveMatchState::ReadyToDelegate(match_state) => {
            plan_responder(match_state.responder(), side, || {
                HeroIntent::CreateChild(ChildIntent {
                    tournament,
                    match_id,
                    commitment,
                    side,
                    match_state,
                })
            })
        }
        LiveMatchState::SealedLeaf(match_state) => {
            HeroDecision::Act(HeroIntent::ProveLeaf(ProofIntent {
                tournament,
                match_id,
                commitment,
                side,
                match_state,
            }))
        }
        LiveMatchState::AwaitingChild(_) => {
            let child = snapshot
                .child()
                .expect("validated awaiting-child snapshots carry their child");
            plan_hero(child)
        }
    }
}

fn plan_timeout_winner(
    snapshot: &SemanticSnapshot,
    engagement: Engagement,
    winner: MatchSide,
    deferred_charge: BlockDuration,
) -> HeroDecision {
    if engagement.local_side() != winner {
        return HeroDecision::Wait(WaitReason::OpponentWinsByTimeout { winner });
    }

    HeroDecision::Act(HeroIntent::ClaimTimeout(TimeoutIntent {
        tournament: snapshot.descriptor().address(),
        match_id: engagement.match_id(),
        commitment: snapshot.local_commitment(),
        survivor: winner,
        deferred_charge,
    }))
}

fn plan_responder(
    responder: MatchSide,
    local_side: MatchSide,
    action: impl FnOnce() -> HeroIntent,
) -> HeroDecision {
    if responder == local_side {
        HeroDecision::Act(action())
    } else {
        HeroDecision::Wait(WaitReason::OpponentTurn { responder })
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::U256;

    use super::*;
    use crate::tournament::domain::{
        AwaitingChildMatch, EliminationReason, EliminationRecord, InnerWinner, JoinDisposition,
        LocalCommitmentStanding, MatchCoordinate, ReadyToSealMatch, RootWinner, SealedDivergence,
        TournamentDescriptor, TournamentKind, WaitingChildren,
    };

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn match_id() -> MatchID {
        MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        }
    }

    fn descriptor(
        address: Address,
        level: u64,
        levels: u64,
        initial_hash: Digest,
        base_cycle: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            levels,
            initial_hash,
            U256::from(base_cycle),
            3,
            4,
        )
        .unwrap()
    }

    fn root_descriptor(kind: TournamentKind) -> TournamentDescriptor {
        let levels = match kind {
            TournamentKind::Leaf => 1,
            TournamentKind::NonLeaf => 2,
        };
        descriptor(address(10), 0, levels, digest(9), 0)
    }

    fn coordinate(position: u64) -> MatchCoordinate {
        MatchCoordinate::new(U256::from(position), U256::from(position * 8))
    }

    fn bisecting(responder: MatchSide) -> BisectingMatch {
        // Total height four and remaining height two means commitment one
        // responds again after two advances.
        assert_eq!(responder, MatchSide::One);
        BisectingMatch::try_new(
            digest(3),
            WaitingChildren::new(digest(4), digest(5)),
            coordinate(0),
            2,
            responder,
        )
        .unwrap()
    }

    fn ready(responder: MatchSide) -> ReadyToSealMatch {
        // Total height four and remaining height one means commitment two.
        assert_eq!(responder, MatchSide::Two);
        ReadyToSealMatch::new(
            digest(3),
            WaitingChildren::new(digest(4), digest(5)),
            coordinate(0),
            responder,
        )
    }

    fn divergence() -> SealedDivergence {
        SealedDivergence::new(digest(20), coordinate(3), digest(21), digest(22))
    }

    fn live_snapshot(
        kind: TournamentKind,
        local_side: MatchSide,
        state: LiveMatchState,
        timeout: TimeoutDisposition,
    ) -> SemanticSnapshot {
        let local = local_side.commitment(match_id());
        let engagement = Engagement::try_new(local, match_id(), state, timeout).unwrap();
        SemanticSnapshot::try_new(
            root_descriptor(kind),
            TournamentStanding::MatchesActive {
                // An engaged local commitment may coexist with an unrelated
                // dangling candidate.
                candidate: Some(digest(99)),
                joins: JoinDisposition::Closed,
            },
            local,
            LocalCommitmentStanding::Engaged(engagement),
            None,
            None,
        )
        .unwrap()
    }

    fn root_snapshot(
        standing: TournamentStanding,
        local: Digest,
        local_standing: LocalCommitmentStanding,
    ) -> SemanticSnapshot {
        SemanticSnapshot::try_new(
            root_descriptor(TournamentKind::Leaf),
            standing,
            local,
            local_standing,
            None,
            None,
        )
        .unwrap()
    }

    #[test]
    fn terminal_root_results_are_distinct_and_have_priority() {
        let ours = digest(1);
        let won = root_snapshot(
            TournamentStanding::RootWinner(RootWinner::new(ours, digest(30))),
            ours,
            LocalCommitmentStanding::Candidate,
        );
        assert_eq!(plan_hero(&won), HeroDecision::Terminal(HeroTerminal::Won));

        let other = digest(2);
        let lost = root_snapshot(
            TournamentStanding::RootWinner(RootWinner::new(other, digest(31))),
            ours,
            LocalCommitmentStanding::NotJoined,
        );
        assert_eq!(plan_hero(&lost), HeroDecision::Terminal(HeroTerminal::Lost));

        let failed = root_snapshot(
            TournamentStanding::RootFailed,
            ours,
            LocalCommitmentStanding::NotJoined,
        );
        assert_eq!(
            plan_hero(&failed),
            HeroDecision::Terminal(HeroTerminal::FailedNoWinner)
        );
    }

    #[test]
    fn current_joinability_selects_join_or_wait() {
        let local = digest(1);
        for (joins, expected) in [
            (
                JoinDisposition::Open,
                HeroDecision::Act(HeroIntent::Join(JoinIntent {
                    tournament: address(10),
                    commitment: local,
                })),
            ),
            (
                JoinDisposition::Closed,
                HeroDecision::Wait(WaitReason::JoinsClosed),
            ),
        ] {
            let snapshot = root_snapshot(
                TournamentStanding::MatchesActive {
                    candidate: None,
                    joins,
                },
                local,
                LocalCommitmentStanding::NotJoined,
            );
            assert_eq!(plan_hero(&snapshot), expected);
        }

        let awaiting_closure = root_snapshot(
            TournamentStanding::AwaitingClosure { candidate: None },
            local,
            LocalCommitmentStanding::NotJoined,
        );
        assert!(matches!(
            plan_hero(&awaiting_closure),
            HeroDecision::Act(HeroIntent::Join(_))
        ));
    }

    #[test]
    fn candidate_wait_reason_tracks_current_tournament_standing() {
        let local = digest(1);
        let blocked = root_snapshot(
            TournamentStanding::MatchesActive {
                candidate: Some(local),
                joins: JoinDisposition::Open,
            },
            local,
            LocalCommitmentStanding::Candidate,
        );
        assert_eq!(
            plan_hero(&blocked),
            HeroDecision::Wait(WaitReason::CandidateBlockedByMatches)
        );

        let closing = root_snapshot(
            TournamentStanding::AwaitingClosure {
                candidate: Some(local),
            },
            local,
            LocalCommitmentStanding::Candidate,
        );
        assert_eq!(
            plan_hero(&closing),
            HeroDecision::Wait(WaitReason::AwaitingTournamentClosure)
        );
    }

    #[test]
    fn eliminated_local_commitment_is_terminally_lost() {
        let local = digest(1);
        let record =
            EliminationRecord::try_new(local, match_id(), EliminationReason::Timeout, None)
                .unwrap();
        let snapshot = root_snapshot(
            TournamentStanding::MatchesActive {
                candidate: Some(digest(99)),
                joins: JoinDisposition::Closed,
            },
            local,
            LocalCommitmentStanding::Eliminated(record),
        );
        assert_eq!(
            plan_hero(&snapshot),
            HeroDecision::Terminal(HeroTerminal::Lost)
        );
    }

    #[test]
    fn timeout_disposition_outranks_every_actionable_phase() {
        let phases = [
            (
                TournamentKind::Leaf,
                LiveMatchState::Bisecting(bisecting(MatchSide::One)),
            ),
            (
                TournamentKind::Leaf,
                LiveMatchState::ReadyToSealLeaf(ready(MatchSide::Two)),
            ),
            (
                TournamentKind::NonLeaf,
                LiveMatchState::ReadyToDelegate(ready(MatchSide::Two)),
            ),
            (
                TournamentKind::Leaf,
                LiveMatchState::SealedLeaf(SealedLeafMatch::new(divergence())),
            ),
        ];

        for (kind, state) in phases {
            let (winner, loser) = match state.responder() {
                Some(MatchSide::One) => (MatchSide::Two, MatchSide::One),
                Some(MatchSide::Two) => (MatchSide::One, MatchSide::Two),
                None => (MatchSide::One, MatchSide::Two),
            };
            let disposition = match winner {
                MatchSide::One => TimeoutDisposition::OneWins {
                    deferred_charge: BlockDuration::ZERO,
                },
                MatchSide::Two => TimeoutDisposition::TwoWins {
                    deferred_charge: BlockDuration::ZERO,
                },
            };

            let ours_wins = live_snapshot(kind, winner, state, disposition);
            assert!(matches!(
                plan_hero(&ours_wins),
                HeroDecision::Act(HeroIntent::ClaimTimeout(_))
            ));

            let opponent_wins = live_snapshot(kind, loser, state, disposition);
            assert_eq!(
                plan_hero(&opponent_wins),
                HeroDecision::Wait(WaitReason::OpponentWinsByTimeout { winner })
            );

            let eliminate = live_snapshot(kind, winner, state, TimeoutDisposition::EliminateBoth);
            assert_eq!(
                plan_hero(&eliminate),
                HeroDecision::Wait(WaitReason::MatchEliminable)
            );
        }
    }

    #[test]
    fn authoritative_sealed_leaf_winner_persists_until_eliminate_both() {
        let state = LiveMatchState::SealedLeaf(SealedLeafMatch::new(divergence()));

        // These are successive contract-authoritative observations: no clock
        // arithmetic or midpoint is reconstructed by the planner.
        for disposition in [
            TimeoutDisposition::OneWins {
                deferred_charge: BlockDuration::ZERO,
            },
            TimeoutDisposition::OneWins {
                deferred_charge: BlockDuration::ZERO,
            },
        ] {
            let snapshot = live_snapshot(TournamentKind::Leaf, MatchSide::One, state, disposition);
            assert!(matches!(
                plan_hero(&snapshot),
                HeroDecision::Act(HeroIntent::ClaimTimeout(_))
            ));
        }

        let later = live_snapshot(
            TournamentKind::Leaf,
            MatchSide::One,
            state,
            TimeoutDisposition::EliminateBoth,
        );
        assert_eq!(
            plan_hero(&later),
            HeroDecision::Wait(WaitReason::MatchEliminable)
        );
    }

    #[test]
    fn action_intents_preserve_locators_and_semantic_payloads() {
        let bisecting = bisecting(MatchSide::One);
        let bisecting_state = LiveMatchState::Bisecting(bisecting);
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::Two,
                bisecting_state,
                TimeoutDisposition::TwoWins {
                    deferred_charge: BlockDuration::from_blocks(7),
                },
            )),
            HeroDecision::Act(HeroIntent::ClaimTimeout(TimeoutIntent {
                tournament: address(10),
                match_id: match_id(),
                commitment: digest(2),
                survivor: MatchSide::Two,
                deferred_charge: BlockDuration::from_blocks(7),
            }))
        );
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::One,
                bisecting_state,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::Advance(AdvanceIntent {
                tournament: address(10),
                match_id: match_id(),
                commitment: digest(1),
                side: MatchSide::One,
                match_state: bisecting,
            }))
        );

        let ready = ready(MatchSide::Two);
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::Two,
                LiveMatchState::ReadyToSealLeaf(ready),
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::SealLeaf(SealIntent {
                tournament: address(10),
                match_id: match_id(),
                commitment: digest(2),
                side: MatchSide::Two,
                match_state: ready,
            }))
        );
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::NonLeaf,
                MatchSide::Two,
                LiveMatchState::ReadyToDelegate(ready),
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::CreateChild(ChildIntent {
                tournament: address(10),
                match_id: match_id(),
                commitment: digest(2),
                side: MatchSide::Two,
                match_state: ready,
            }))
        );

        let sealed = SealedLeafMatch::new(divergence());
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::One,
                LiveMatchState::SealedLeaf(sealed),
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::ProveLeaf(ProofIntent {
                tournament: address(10),
                match_id: match_id(),
                commitment: digest(1),
                side: MatchSide::One,
                match_state: sealed,
            }))
        );
    }

    #[test]
    fn no_timeout_phase_table_is_exhaustive() {
        let bisect = LiveMatchState::Bisecting(bisecting(MatchSide::One));
        assert!(matches!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::One,
                bisect,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::Advance(_))
        ));
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::Two,
                bisect,
                TimeoutDisposition::None,
            )),
            HeroDecision::Wait(WaitReason::OpponentTurn {
                responder: MatchSide::One
            })
        );

        let ready_leaf = LiveMatchState::ReadyToSealLeaf(ready(MatchSide::Two));
        assert!(matches!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::Two,
                ready_leaf,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::SealLeaf(_))
        ));
        assert!(matches!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::One,
                ready_leaf,
                TimeoutDisposition::None,
            )),
            HeroDecision::Wait(WaitReason::OpponentTurn { .. })
        ));

        let ready_child = LiveMatchState::ReadyToDelegate(ready(MatchSide::Two));
        assert!(matches!(
            plan_hero(&live_snapshot(
                TournamentKind::NonLeaf,
                MatchSide::Two,
                ready_child,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::CreateChild(_))
        ));
        assert!(matches!(
            plan_hero(&live_snapshot(
                TournamentKind::NonLeaf,
                MatchSide::One,
                ready_child,
                TimeoutDisposition::None,
            )),
            HeroDecision::Wait(WaitReason::OpponentTurn { .. })
        ));

        let sealed = LiveMatchState::SealedLeaf(SealedLeafMatch::new(divergence()));
        for side in [MatchSide::One, MatchSide::Two] {
            assert!(matches!(
                plan_hero(&live_snapshot(
                    TournamentKind::Leaf,
                    side,
                    sealed,
                    TimeoutDisposition::None,
                )),
                HeroDecision::Act(HeroIntent::ProveLeaf(_))
            ));
        }
    }

    #[test]
    fn awaiting_child_recurses_and_returns_only_the_child_decision() {
        let parent_descriptor = root_descriptor(TournamentKind::NonLeaf);
        let parent_commitment = digest(1);
        let parent_match = match_id();
        let parent_link =
            ParentLink::try_new(parent_descriptor.address(), parent_match, parent_commitment)
                .unwrap();
        let child_descriptor = descriptor(address(20), 1, 2, digest(20), 24);
        let child = SemanticSnapshot::try_new(
            child_descriptor,
            TournamentStanding::MatchesActive {
                candidate: None,
                joins: JoinDisposition::Open,
            },
            digest(40),
            LocalCommitmentStanding::NotJoined,
            Some(parent_link),
            None,
        )
        .unwrap();

        let awaiting =
            AwaitingChildMatch::try_new(divergence(), child_descriptor.address()).unwrap();
        let engagement = Engagement::try_new(
            parent_commitment,
            parent_match,
            LiveMatchState::AwaitingChild(awaiting),
            TimeoutDisposition::None,
        )
        .unwrap();
        let parent = SemanticSnapshot::try_new(
            parent_descriptor,
            TournamentStanding::MatchesActive {
                candidate: None,
                joins: JoinDisposition::Closed,
            },
            parent_commitment,
            LocalCommitmentStanding::Engaged(engagement),
            None,
            Some(child),
        )
        .unwrap();

        let decision = plan_hero(&parent);
        assert_eq!(
            decision,
            HeroDecision::Act(HeroIntent::Join(JoinIntent {
                tournament: child_descriptor.address(),
                commitment: digest(40),
            }))
        );
        assert_eq!(plan_hero(&parent), decision);
    }

    #[test]
    fn inner_result_propagates_ours_or_terminates_when_it_maps_to_other_parent() {
        let parent_match = match_id();
        let parent_commitment = digest(1);
        let parent_link =
            ParentLink::try_new(address(10), parent_match, parent_commitment).unwrap();
        let child_descriptor = descriptor(address(20), 1, 2, digest(20), 24);
        let child_winner = digest(40);

        let ours = SemanticSnapshot::try_new(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(parent_commitment, child_winner)),
            child_winner,
            LocalCommitmentStanding::Candidate,
            Some(parent_link),
            None,
        )
        .unwrap();
        assert_eq!(
            plan_hero(&ours),
            HeroDecision::Act(HeroIntent::PropagateChild(PropagationIntent {
                parent_tournament: address(10),
                child_tournament: address(20),
                parent_match,
                parent_commitment,
                parent_side: MatchSide::One,
                child_winner,
            }))
        );

        let other_parent = digest(2);
        let lost = SemanticSnapshot::try_new(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(other_parent, child_winner)),
            child_winner,
            LocalCommitmentStanding::Candidate,
            Some(parent_link),
            None,
        )
        .unwrap();
        assert_eq!(plan_hero(&lost), HeroDecision::Terminal(HeroTerminal::Lost));
    }

    #[test]
    fn child_elimination_never_becomes_a_hero_action() {
        let parent_link = ParentLink::try_new(address(10), match_id(), digest(1)).unwrap();
        for (reason, local, local_standing) in [
            (
                InnerEliminationReason::NoCandidate,
                digest(40),
                LocalCommitmentStanding::NotJoined,
            ),
            (
                InnerEliminationReason::WinnerExpired {
                    candidate: digest(41),
                },
                digest(41),
                LocalCommitmentStanding::Candidate,
            ),
        ] {
            let child = SemanticSnapshot::try_new(
                descriptor(address(20), 1, 2, digest(20), 24),
                TournamentStanding::InnerEliminable { reason },
                local,
                local_standing,
                Some(parent_link),
                None,
            )
            .unwrap();
            assert_eq!(
                plan_hero(&child),
                HeroDecision::Wait(WaitReason::ChildEliminable { reason })
            );
        }
    }
}
