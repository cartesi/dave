//! Pure Hero policy over the semantic tournament domain.
//!
//! Planning chooses one terminal, wait, or action decision. It performs no
//! provider calls, constructs no Merkle material, and owns no transaction
//! sender. The production actor invokes it only on an assembled snapshot.

use alloy::primitives::Address;

use crate::{
    merkle::Digest,
    tournament::domain::{
        Engagement, InnerEliminationReason, LiveMatchState, MatchDeletionReason, MatchSide,
        SemanticSnapshot, TimeoutDisposition, TournamentStanding,
    },
};

/// The complete result of planning one accepted observation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeroDecision {
    Terminal(HeroTerminal),
    Wait(WaitReason),
    Act(HeroIntent),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeroTerminal {
    Won,
    Lost(Loss),
    FailedNoWinner,
}

/// How the local commitment lost, for the operator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Loss {
    /// Another commitment won the root, ending in `final_state`.
    Root { final_state: Digest },
    /// The local commitment was eliminated in `tournament`.
    Eliminated {
        tournament: Address,
        reason: MatchDeletionReason,
    },
    /// Another commitment class won the local match's child `tournament`.
    Child { tournament: Address },
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

impl WaitReason {
    /// The local commitment already missed an obligation: it never joined
    /// before joins closed, its clock expired, both clocks of its match
    /// expired, or its match's child has no winner to propagate. Each means
    /// the node failed to take part, which is never in the plan.
    pub const fn missed(self) -> bool {
        matches!(
            self,
            Self::JoinsClosed
                | Self::OpponentWinsByTimeout { .. }
                | Self::MatchEliminable
                | Self::ChildEliminable { .. }
        )
    }
}

/// Where to act. Preparation reads the match from the context that produced
/// the intent, so an intent names only the tournaments its call targets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeroIntent {
    /// Names the commitment too: the actor joins only when Solid plans this
    /// exact join, and after a reorg one child address can carry another
    /// descriptor, hence another local commitment.
    Join {
        tournament: Address,
        commitment: Digest,
    },
    ClaimTimeout {
        tournament: Address,
    },
    Advance {
        tournament: Address,
    },
    SealLeaf {
        tournament: Address,
    },
    CreateChild {
        tournament: Address,
    },
    ProveLeaf {
        tournament: Address,
    },
    PropagateChild {
        parent_tournament: Address,
        child_tournament: Address,
    },
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
            return HeroDecision::Terminal(HeroTerminal::Lost(Loss::Root {
                final_state: winner.final_state(),
            }));
        }
        TournamentStanding::RootFailed => {
            return HeroDecision::Terminal(HeroTerminal::FailedNoWinner);
        }
        TournamentStanding::InnerWinner(winner) => {
            let parent = snapshot
                .parent()
                .expect("assembly links every inner level to its parent");
            if winner.parent_commitment() != parent.parent_commitment() {
                return HeroDecision::Terminal(HeroTerminal::Lost(Loss::Child {
                    tournament: snapshot.descriptor().address(),
                }));
            }
            return HeroDecision::Act(HeroIntent::PropagateChild {
                parent_tournament: parent.parent_tournament(),
                child_tournament: snapshot.descriptor().address(),
            });
        }
        TournamentStanding::InnerEliminable { reason } => {
            return HeroDecision::Wait(WaitReason::ChildEliminable { reason });
        }
        TournamentStanding::MatchesActive { .. } | TournamentStanding::AwaitingClosure => {}
    }

    match snapshot.local_standing() {
        crate::tournament::domain::LocalCommitmentStanding::NotJoined => {
            if snapshot.standing().accepts_joins() {
                HeroDecision::Act(HeroIntent::Join {
                    tournament: snapshot.descriptor().address(),
                    commitment: snapshot.local_commitment(),
                })
            } else {
                HeroDecision::Wait(WaitReason::JoinsClosed)
            }
        }
        crate::tournament::domain::LocalCommitmentStanding::Candidate => {
            match snapshot.standing() {
                TournamentStanding::MatchesActive { .. } => {
                    HeroDecision::Wait(WaitReason::CandidateBlockedByMatches)
                }
                TournamentStanding::AwaitingClosure => {
                    HeroDecision::Wait(WaitReason::AwaitingTournamentClosure)
                }
                _ => unreachable!("terminal standings returned before local planning"),
            }
        }
        crate::tournament::domain::LocalCommitmentStanding::Eliminated { reason } => {
            HeroDecision::Terminal(HeroTerminal::Lost(Loss::Eliminated {
                tournament: snapshot.descriptor().address(),
                reason,
            }))
        }
        crate::tournament::domain::LocalCommitmentStanding::Engaged(engagement) => {
            plan_engagement(snapshot, engagement)
        }
    }
}

fn plan_engagement(snapshot: &SemanticSnapshot, engagement: Engagement) -> HeroDecision {
    let tournament = snapshot.descriptor().address();
    let side = engagement.local_side();

    match engagement.live().timeout() {
        TimeoutDisposition::OneWins { .. } => {
            return plan_timeout_winner(tournament, side, MatchSide::One);
        }
        TimeoutDisposition::TwoWins { .. } => {
            return plan_timeout_winner(tournament, side, MatchSide::Two);
        }
        TimeoutDisposition::EliminateBoth => {
            return HeroDecision::Wait(WaitReason::MatchEliminable);
        }
        TimeoutDisposition::None => {}
    }

    match engagement.live().state() {
        LiveMatchState::Bisecting(match_state) => plan_responder(
            match_state.responder(),
            side,
            HeroIntent::Advance { tournament },
        ),
        LiveMatchState::ReadyToSealLeaf(match_state) => plan_responder(
            match_state.responder(),
            side,
            HeroIntent::SealLeaf { tournament },
        ),
        LiveMatchState::ReadyToDelegate(match_state) => plan_responder(
            match_state.responder(),
            side,
            HeroIntent::CreateChild { tournament },
        ),
        LiveMatchState::SealedLeaf(_) => HeroDecision::Act(HeroIntent::ProveLeaf { tournament }),
        LiveMatchState::AwaitingChild(_) => {
            let child = snapshot
                .child()
                .expect("assembly descends into every delegated match's child");
            plan_hero(child)
        }
    }
}

fn plan_timeout_winner(
    tournament: Address,
    local_side: MatchSide,
    winner: MatchSide,
) -> HeroDecision {
    if local_side != winner {
        return HeroDecision::Wait(WaitReason::OpponentWinsByTimeout { winner });
    }

    HeroDecision::Act(HeroIntent::ClaimTimeout { tournament })
}

fn plan_responder(responder: MatchSide, local_side: MatchSide, action: HeroIntent) -> HeroDecision {
    if responder == local_side {
        HeroDecision::Act(action)
    } else {
        HeroDecision::Wait(WaitReason::OpponentTurn { responder })
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::U256;

    use super::*;
    use crate::tournament::{
        MatchID,
        domain::{
            BisectingMatch, BlockDuration, InnerWinner, JoinDisposition, LiveMatch,
            LocalCommitmentStanding, MatchCoordinate, ParentLink, ReadyToSealMatch, RootWinner,
            SealedDivergence, SealedLeafMatch, TournamentDescriptor, TournamentKind,
            WaitingChildren,
        },
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
        kind: TournamentKind,
        initial_hash: Digest,
        base_cycle: u64,
    ) -> TournamentDescriptor {
        TournamentDescriptor::try_new(
            address,
            level,
            kind,
            initial_hash,
            U256::from(base_cycle),
            3,
            4,
        )
        .unwrap()
    }

    fn root_descriptor(kind: TournamentKind) -> TournamentDescriptor {
        descriptor(address(10), 0, kind, digest(9), 0)
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
        let local = match local_side {
            MatchSide::One => match_id().commitment_one,
            MatchSide::Two => match_id().commitment_two,
        };
        let engagement = Engagement::new(match_id(), local_side, LiveMatch::new(state, timeout));
        SemanticSnapshot::new(
            root_descriptor(kind),
            TournamentStanding::MatchesActive {
                joins: JoinDisposition::Closed,
            },
            local,
            LocalCommitmentStanding::Engaged(engagement),
            None,
            None,
        )
    }

    fn root_snapshot(
        standing: TournamentStanding,
        local: Digest,
        local_standing: LocalCommitmentStanding,
    ) -> SemanticSnapshot {
        SemanticSnapshot::new(
            root_descriptor(TournamentKind::Leaf),
            standing,
            local,
            local_standing,
            None,
            None,
        )
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
        assert_eq!(
            plan_hero(&lost),
            HeroDecision::Terminal(HeroTerminal::Lost(Loss::Root {
                final_state: digest(31)
            }))
        );

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
                HeroDecision::Act(HeroIntent::Join {
                    tournament: address(10),
                    commitment: local,
                }),
            ),
            (
                JoinDisposition::Closed,
                HeroDecision::Wait(WaitReason::JoinsClosed),
            ),
        ] {
            let snapshot = root_snapshot(
                TournamentStanding::MatchesActive { joins },
                local,
                LocalCommitmentStanding::NotJoined,
            );
            assert_eq!(plan_hero(&snapshot), expected);
        }

        let awaiting_closure = root_snapshot(
            TournamentStanding::AwaitingClosure,
            local,
            LocalCommitmentStanding::NotJoined,
        );
        assert!(matches!(
            plan_hero(&awaiting_closure),
            HeroDecision::Act(HeroIntent::Join { .. })
        ));
    }

    #[test]
    fn candidate_wait_reason_tracks_current_tournament_standing() {
        let local = digest(1);
        let blocked = root_snapshot(
            TournamentStanding::MatchesActive {
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
            TournamentStanding::AwaitingClosure,
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
        let snapshot = root_snapshot(
            TournamentStanding::MatchesActive {
                joins: JoinDisposition::Closed,
            },
            digest(1),
            LocalCommitmentStanding::Eliminated {
                reason: MatchDeletionReason::Timeout,
            },
        );
        assert_eq!(
            plan_hero(&snapshot),
            HeroDecision::Terminal(HeroTerminal::Lost(Loss::Eliminated {
                tournament: address(10),
                reason: MatchDeletionReason::Timeout,
            }))
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
            assert_eq!(
                plan_hero(&ours_wins),
                HeroDecision::Act(HeroIntent::ClaimTimeout {
                    tournament: address(10)
                })
            );

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
                HeroDecision::Act(HeroIntent::ClaimTimeout { .. })
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
    fn no_timeout_phase_table_is_exhaustive() {
        let bisect = LiveMatchState::Bisecting(bisecting(MatchSide::One));
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::One,
                bisect,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::Advance {
                tournament: address(10)
            })
        );
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
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::Leaf,
                MatchSide::Two,
                ready_leaf,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::SealLeaf {
                tournament: address(10)
            })
        );
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
        assert_eq!(
            plan_hero(&live_snapshot(
                TournamentKind::NonLeaf,
                MatchSide::Two,
                ready_child,
                TimeoutDisposition::None,
            )),
            HeroDecision::Act(HeroIntent::CreateChild {
                tournament: address(10)
            })
        );
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
            assert_eq!(
                plan_hero(&live_snapshot(
                    TournamentKind::Leaf,
                    side,
                    sealed,
                    TimeoutDisposition::None,
                )),
                HeroDecision::Act(HeroIntent::ProveLeaf {
                    tournament: address(10)
                })
            );
        }
    }

    #[test]
    fn awaiting_child_recurses_and_returns_only_the_child_decision() {
        let parent_descriptor = root_descriptor(TournamentKind::NonLeaf);
        let parent_commitment = digest(1);
        let parent_match = match_id();
        let parent_link = ParentLink::new(
            parent_descriptor.address(),
            parent_match,
            parent_commitment,
            MatchSide::One,
        );
        let child_descriptor = descriptor(address(20), 1, TournamentKind::Leaf, digest(20), 24);
        let child = SemanticSnapshot::new(
            child_descriptor,
            TournamentStanding::MatchesActive {
                joins: JoinDisposition::Open,
            },
            digest(40),
            LocalCommitmentStanding::NotJoined,
            Some(parent_link),
            None,
        );

        let engagement = Engagement::new(
            parent_match,
            MatchSide::One,
            LiveMatch::new(
                LiveMatchState::AwaitingChild(child_descriptor.address()),
                TimeoutDisposition::None,
            ),
        );
        let parent = SemanticSnapshot::new(
            parent_descriptor,
            TournamentStanding::MatchesActive {
                joins: JoinDisposition::Closed,
            },
            parent_commitment,
            LocalCommitmentStanding::Engaged(engagement),
            None,
            Some(child),
        );

        let decision = plan_hero(&parent);
        assert_eq!(
            decision,
            HeroDecision::Act(HeroIntent::Join {
                tournament: child_descriptor.address(),
                commitment: digest(40),
            })
        );
        assert_eq!(plan_hero(&parent), decision);
    }

    #[test]
    fn inner_result_propagates_ours_or_terminates_when_it_maps_to_other_parent() {
        let parent_match = match_id();
        let parent_commitment = digest(1);
        let parent_link =
            ParentLink::new(address(10), parent_match, parent_commitment, MatchSide::One);
        let child_descriptor = descriptor(address(20), 1, TournamentKind::Leaf, digest(20), 24);
        let child_winner = digest(40);

        let ours = SemanticSnapshot::new(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(parent_commitment, child_winner)),
            child_winner,
            LocalCommitmentStanding::Candidate,
            Some(parent_link),
            None,
        );
        assert_eq!(
            plan_hero(&ours),
            HeroDecision::Act(HeroIntent::PropagateChild {
                parent_tournament: address(10),
                child_tournament: address(20),
            })
        );

        let other_parent = digest(2);
        let lost = SemanticSnapshot::new(
            child_descriptor,
            TournamentStanding::InnerWinner(InnerWinner::new(other_parent, child_winner)),
            child_winner,
            LocalCommitmentStanding::Candidate,
            Some(parent_link),
            None,
        );
        assert_eq!(
            plan_hero(&lost),
            HeroDecision::Terminal(HeroTerminal::Lost(Loss::Child {
                tournament: child_descriptor.address()
            }))
        );
    }

    #[test]
    fn child_elimination_never_becomes_a_hero_action() {
        let parent_link = ParentLink::new(address(10), match_id(), digest(1), MatchSide::One);
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
            let child = SemanticSnapshot::new(
                descriptor(address(20), 1, TournamentKind::Leaf, digest(20), 24),
                TournamentStanding::InnerEliminable { reason },
                local,
                local_standing,
                Some(parent_link),
                None,
            );
            assert_eq!(
                plan_hero(&child),
                HeroDecision::Wait(WaitReason::ChildEliminable { reason })
            );
        }
    }
}
