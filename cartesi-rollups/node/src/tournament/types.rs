//! The tournament value types shared by the fold, the reader, and the
//! Hero, and the reader's product: [`DisputeState`], the dispute's
//! event-derived structure plus one disposable semantic observation.

use crate::merkle::Digest;
use alloy::primitives::Address;
#[cfg(test)]
use alloy::primitives::U256;
use std::collections::HashMap;

use crate::chain::ChainHead;
#[cfg(test)]
use crate::tournament::adapter::ShadowReport;
use crate::tournament::adapter::TournamentObservation;
use crate::tournament::fold::{Fold, TournamentFold};

/// Struct used to identify a match.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MatchID {
    pub commitment_one: Digest,
    pub commitment_two: Digest,
}

impl MatchID {
    /// Generates a new [Digest]
    pub fn hash(&self) -> Digest {
        self.commitment_one.join(&self.commitment_two)
    }
}

// TODO: this can be optimized if the bindings generated with only one shared `Id` struct
impl From<MatchID> for cartesi_prt_contracts::tournament::Match::Id {
    fn from(match_id: MatchID) -> Self {
        cartesi_prt_contracts::tournament::Match::Id {
            commitmentOne: match_id.commitment_one.into(),
            commitmentTwo: match_id.commitment_two.into(),
        }
    }
}

/// Struct used to communicate the state of a clock.
#[cfg(test)]
#[derive(Clone, Copy, Debug)]
pub struct ClockState {
    pub allowance: u64,
    pub start_instant: u64,
    pub block_number: u64,
}

// Clock arithmetic is saturating throughout: these values come off
// the chain, and a display or comparison must degrade on a weird
// read, never crash the node. An unpinned overlay read once handed
// this type a clock started AFTER the tick's block stamp, and the
// display's subtraction underflow killed the epoch-manager thread
// (kill_mid_match, 2026-07-09). The reader now pins every read at
// the tick's block, which makes that state unreachable; saturation
// keeps the type total anyway.
#[cfg(test)]
impl ClockState {
    pub fn has_time(&self) -> bool {
        if self.start_instant == 0 {
            true
        } else {
            self.deadline() > self.block_number
        }
    }

    pub fn time_since_timeout(&self) -> u64 {
        if self.start_instant == 0 {
            0
        } else {
            self.block_number.saturating_sub(self.deadline())
        }
    }

    /// Live remaining time: the full allowance while paused, the
    /// undrained balance while ticking (Clock.sol's remainingAt).
    pub fn remaining(&self) -> u64 {
        if self.start_instant == 0 {
            self.allowance
        } else {
            self.allowance
                .saturating_sub(self.block_number.saturating_sub(self.start_instant))
        }
    }

    // deadline of clock if it's ticking
    fn deadline(&self) -> u64 {
        self.start_instant.saturating_add(self.allowance)
    }
}

/// Timeout resolution for one match's clock pair, in match orientation.
#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeoutOutcome {
    None,
    OneWins,
    TwoWins,
    EliminateBoth,
}

/// Classify timeout resolution exactly as the contract does
/// (MatchClocks.classifyTimeoutAt): a winner must retain strictly
/// positive time after the expired side's overdue duration is
/// charged, and equality eliminates both. Both clocks carry the same
/// tick's block stamp; the reader pins every read at that height.
#[cfg(test)]
pub fn classify_timeout(one: &ClockState, two: &ClockState) -> TimeoutOutcome {
    if !one.has_time() {
        if two.remaining() > one.time_since_timeout() {
            TimeoutOutcome::TwoWins
        } else {
            TimeoutOutcome::EliminateBoth
        }
    } else if !two.has_time() {
        if one.remaining() > two.time_since_timeout() {
            TimeoutOutcome::OneWins
        } else {
            TimeoutOutcome::EliminateBoth
        }
    } else {
        TimeoutOutcome::None
    }
}

#[cfg(test)]
impl std::fmt::Display for ClockState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.start_instant == 0 {
            write!(f, "clock paused, {} blocks left", self.allowance)
        } else if self.has_time() {
            write!(f, "clock ticking, {} blocks left", self.remaining())
        } else {
            write!(
                f,
                "clock ticking, {} blocks overdue",
                self.time_since_timeout()
            )
        }
    }
}

/// Enum used to represent the winner of a tournament.
#[cfg(test)]
#[derive(Clone, PartialEq, Debug)]
pub enum TournamentWinner {
    Root(Digest, Digest),
    Inner(Digest, Digest),
}

/// What events cannot determine about a running match (see the fold
/// module doc): the contract's live positioning, point-read each tick.
#[cfg(test)]
#[derive(Clone, Copy, Debug)]
pub struct MatchLive {
    pub other_parent: Digest,
    pub left_node: Digest,
    pub right_node: Digest,
    pub running_leaf_position: U256,
    pub current_height: u64,
    pub leaf_cycle: U256,
}

/// One reachable tournament's point-read overlay: everything the
/// chain owns that the event fold deliberately does not derive.
#[cfg(test)]
#[derive(Clone, Debug)]
pub struct TournamentOverlay {
    /// Level geometry from tournamentLevelConstants; the level itself
    /// is asserted against the fold's at assembly.
    pub max_level: u64,
    pub log2_stride: u64,
    pub log2_stride_count: u64,
    /// The leftmost big-cycle this tournament arbitrates: the parent's
    /// sealed match leaf cycle, zero at the root.
    pub base_cycle: U256,
    pub winner: Option<TournamentWinner>,
    pub can_be_eliminated: bool,
    /// Clock per joined commitment, stamped with the fetch block.
    pub clocks: HashMap<Digest, ClockState>,
    /// Live positioning per live match, keyed by MatchID hash.
    pub live_matches: HashMap<Digest, MatchLive>,
}

/// One accepted dispute observation. The fold owns structural history and may
/// include a disposable number-range tail; `observations` owns point semantics
/// read at `head.hash`. Contract mutators revalidate any action derived from
/// this value.
#[derive(Clone, Debug)]
pub struct DisputeState {
    pub head: ChainHead,
    pub fold: Fold,
    pub observations: HashMap<Address, TournamentObservation>,
}

/// Best-effort evidence from the superseded raw-getter reader. It is never an
/// authority for Hero or GC. It remains only in differential tests; live
/// sampling is deliberately outside the deadline-sensitive reader product.
#[cfg(test)]
#[derive(Clone, Debug)]
pub enum LegacyShadow {
    /// The old overlay completed and passed the strict differential. Reports
    /// contain only explicitly accepted corrections.
    Accepted {
        overlay: HashMap<Address, TournamentOverlay>,
        reports: HashMap<Address, ShadowReport>,
    },
    /// The old overlay or its differential failed. The diagnostic is retained
    /// as migration evidence; the authoritative observation remains usable.
    Rejected { diagnostic: String },
}

#[cfg(test)]
impl LegacyShadow {
    pub fn rejected(diagnostic: impl Into<String>) -> Self {
        Self::Rejected {
            diagnostic: diagnostic.into(),
        }
    }

    pub fn overlay(&self) -> Option<&HashMap<Address, TournamentOverlay>> {
        match self {
            Self::Accepted { overlay, .. } => Some(overlay),
            Self::Rejected { .. } => None,
        }
    }
}

#[cfg(test)]
impl Default for LegacyShadow {
    fn default() -> Self {
        Self::rejected("legacy shadow was not run")
    }
}

impl DisputeState {
    /// A reachable tournament's structure and semantic observation together.
    pub fn tournament(
        &self,
        address: &Address,
    ) -> Option<(&TournamentFold, &TournamentObservation)> {
        let observation = self.observations.get(address)?;
        let fold = self
            .fold
            .tournament(address)
            .expect("observations cover only folded tournaments");
        Some((fold, observation))
    }

    /// Every reachable tournament, parents before children.
    pub fn reachable(&self) -> impl Iterator<Item = (&TournamentFold, &TournamentObservation)> {
        self.fold.tournaments().filter_map(|tf| {
            self.observations
                .get(&tf.address)
                .map(|observation| (tf, observation))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tournament::domain::{JoinDisposition, TournamentDescriptor, TournamentStanding};
    use crate::tournament::fold::{EventKind, TournamentEvent};

    fn digest(byte: u8) -> Digest {
        Digest::from_digest(&[byte; 32]).unwrap()
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn observation(tournament: Address, level: u64, levels: u64) -> TournamentObservation {
        TournamentObservation::from_parts(
            TournamentDescriptor::try_new(tournament, level, levels, digest(1), U256::ZERO, 0, 1)
                .unwrap(),
            TournamentStanding::MatchesActive {
                candidate: None,
                joins: JoinDisposition::Open,
            },
            HashMap::new(),
        )
    }

    /// Reachability is semantic-observation membership: the iterator walks
    /// discovery order and skips tournaments the authoritative reader did not
    /// observe.
    #[test]
    fn dispute_state_serves_only_the_observed() {
        let (root, inner) = (address(1), address(2));
        let mut fold = Fold::new(root);
        for (seed, kind) in [
            (
                10u8,
                EventKind::CommitmentJoined {
                    root: digest(10),
                    final_state: digest(110),
                },
            ),
            (
                20,
                EventKind::CommitmentJoined {
                    root: digest(20),
                    final_state: digest(120),
                },
            ),
        ] {
            let _ = seed;
            fold.apply(&TournamentEvent {
                tournament: root,
                block: 1,
                kind,
            })
            .unwrap();
        }
        fold.apply(&TournamentEvent {
            tournament: root,
            block: 2,
            kind: EventKind::MatchCreated {
                one: digest(10),
                two: digest(20),
                left_of_two: digest(21),
            },
        })
        .unwrap();
        let id_hash = MatchID {
            commitment_one: digest(10),
            commitment_two: digest(20),
        }
        .hash();
        fold.apply(&TournamentEvent {
            tournament: root,
            block: 3,
            kind: EventKind::NewInnerTournament {
                match_id_hash: id_hash,
                child: inner,
            },
        })
        .unwrap();

        // The semantic observation covers the root only: the inner is history.
        let observations = HashMap::from([(root, observation(root, 0, 2))]);
        let dispute = DisputeState {
            head: ChainHead {
                number: 3,
                hash: alloy::primitives::B256::repeat_byte(3),
            },
            fold,
            observations,
        };

        let reachable: Vec<Address> = dispute.reachable().map(|(tf, _)| tf.address).collect();
        assert_eq!(reachable, vec![root]);
        assert!(dispute.tournament(&root).is_some());
        assert!(dispute.tournament(&inner).is_none());
    }

    /// The 2026-07-09 kill_mid_match crash: a clock read fresher than
    /// the tick's block stamp (start_instant beyond block_number) must
    /// display and answer queries, not underflow.
    #[test]
    fn clock_from_the_future_degrades_instead_of_crashing() {
        let clock = ClockState {
            allowance: 300,
            start_instant: 1000,
            block_number: 998,
        };
        assert_eq!(format!("{clock}"), "clock ticking, 300 blocks left");
        assert!(clock.has_time());
        assert_eq!(clock.time_since_timeout(), 0);
    }

    #[test]
    fn clock_states_display_their_phase() {
        let paused = ClockState {
            allowance: 300,
            start_instant: 0,
            block_number: 50,
        };
        assert_eq!(format!("{paused}"), "clock paused, 300 blocks left");

        let ticking = ClockState {
            allowance: 300,
            start_instant: 100,
            block_number: 150,
        };
        assert_eq!(format!("{ticking}"), "clock ticking, 250 blocks left");
        assert!(ticking.has_time());
        assert_eq!(ticking.time_since_timeout(), 0);

        let overdue = ClockState {
            allowance: 300,
            start_instant: 100,
            block_number: 500,
        };
        assert_eq!(format!("{overdue}"), "clock ticking, 100 blocks overdue");
        assert!(!overdue.has_time());
        assert_eq!(overdue.time_since_timeout(), 100);
    }

    fn paused(allowance: u64, block_number: u64) -> ClockState {
        ClockState {
            allowance,
            start_instant: 0,
            block_number,
        }
    }

    fn ticking(allowance: u64, start_instant: u64, block_number: u64) -> ClockState {
        ClockState {
            allowance,
            start_instant,
            block_number,
        }
    }

    fn assert_symmetric(one: ClockState, two: ClockState, expected: TimeoutOutcome) {
        assert_eq!(classify_timeout(&one, &two), expected);
        let mirrored = match expected {
            TimeoutOutcome::OneWins => TimeoutOutcome::TwoWins,
            TimeoutOutcome::TwoWins => TimeoutOutcome::OneWins,
            other => other,
        };
        assert_eq!(classify_timeout(&two, &one), mirrored);
    }

    /// The bisection boundary matrix of MatchClocks.t.sol
    /// (testFuzzBisectionTimeoutBoundaries): the paused side wins from
    /// the running side's deadline until its own allowance equals the
    /// overdue duration, where both are eliminated.
    #[test]
    fn bisection_timeout_matches_the_contract_boundaries() {
        let (start, running_allowance, paused_allowance) = (10, 100, 300);
        let at = |block| {
            (
                ticking(running_allowance, start, block),
                paused(paused_allowance, block),
            )
        };

        let (one, two) = at(start + running_allowance - 1);
        assert_symmetric(one, two, TimeoutOutcome::None);

        let (one, two) = at(start + running_allowance);
        assert_symmetric(one, two, TimeoutOutcome::TwoWins);

        let (one, two) = at(start + running_allowance + paused_allowance - 1);
        assert_symmetric(one, two, TimeoutOutcome::TwoWins);

        let (one, two) = at(start + running_allowance + paused_allowance);
        assert_symmetric(one, two, TimeoutOutcome::EliminateBoth);
    }

    /// The leaf-race boundary matrix of MatchClocks.t.sol
    /// (testFuzzSealedLeafTimeoutBoundaries): both clocks drain in
    /// real time, so the longer side must claim its timeout win
    /// before the midpoint of the combined allowances - NOT within
    /// the opponent's full static allowance, the pre-alignment gate.
    #[test]
    fn leaf_race_timeout_matches_the_contract_boundaries() {
        let (start, short, long) = (10, 100, 300);
        let at = |block| (ticking(short, start, block), ticking(long, start, block));

        let (one, two) = at(start + short - 1);
        assert_symmetric(one, two, TimeoutOutcome::None);

        let (one, two) = at(start + short);
        assert_symmetric(one, two, TimeoutOutcome::TwoWins);

        let (one, two) = at(start + (short + long).div_ceil(2) - 1);
        assert_symmetric(one, two, TimeoutOutcome::TwoWins);

        let (one, two) = at(start + (short + long).div_ceil(2));
        assert_symmetric(one, two, TimeoutOutcome::EliminateBoth);
    }

    /// Equal allowances racing from one instant die together at their
    /// shared deadline - the double elimination the old static-
    /// allowance gate deferred for another full allowance.
    #[test]
    fn equal_leaf_race_eliminates_both_at_the_shared_deadline() {
        let (start, allowance) = (10, 100);
        let at = |block| {
            (
                ticking(allowance, start, block),
                ticking(allowance, start, block),
            )
        };

        let (one, two) = at(start + allowance - 1);
        assert_symmetric(one, two, TimeoutOutcome::None);

        let (one, two) = at(start + allowance);
        assert_symmetric(one, two, TimeoutOutcome::EliminateBoth);
    }

    /// A sealed inner match holds two paused clocks; no timeout
    /// resolution applies while the child tournament runs.
    #[test]
    fn paused_pair_never_times_out() {
        assert_symmetric(paused(100, 5000), paused(300, 5000), TimeoutOutcome::None);
    }
}
