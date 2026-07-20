//! The tournament value types shared by the fold, the reader, and the
//! Hero, and the reader's product: [`DisputeState`], the dispute's
//! event-derived structure plus the per-tick point-read overlay.

use crate::merkle::Digest;
use alloy::primitives::{Address, U256};
use std::collections::HashMap;

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

    // deadline of clock if it's ticking
    fn deadline(&self) -> u64 {
        self.start_instant.saturating_add(self.allowance)
    }
}

impl std::fmt::Display for ClockState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.start_instant == 0 {
            write!(f, "clock paused, {} blocks left", self.allowance)
        } else {
            let time_elapsed = self.block_number.saturating_sub(self.start_instant);
            if self.allowance >= time_elapsed {
                write!(
                    f,
                    "clock ticking, {} blocks left",
                    self.allowance - time_elapsed
                )
            } else {
                write!(
                    f,
                    "clock ticking, {} blocks overdue",
                    time_elapsed - self.allowance
                )
            }
        }
    }
}

/// Enum used to represent the winner of a tournament.
#[derive(Clone, PartialEq, Debug)]
pub enum TournamentWinner {
    Root(Digest, Digest),
    Inner(Digest, Digest),
}

/// What events cannot determine about a running match (see the fold
/// module doc): the contract's live positioning, point-read each tick.
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

/// The reader's product: structure from the event fold, volatile
/// state from the overlay. The overlay covers REACHABLE tournaments
/// only - the root, plus inners whose parent match is still live; a
/// settled inner disappears with its match, exactly as the old
/// recursive walk never reached it.
#[derive(Clone, Debug)]
pub struct DisputeState {
    pub fold: Fold,
    pub overlay: HashMap<Address, TournamentOverlay>,
}

impl DisputeState {
    /// A reachable tournament's structure and overlay together.
    pub fn tournament(&self, address: &Address) -> Option<(&TournamentFold, &TournamentOverlay)> {
        let overlay = self.overlay.get(address)?;
        let fold = self
            .fold
            .tournament(address)
            .expect("overlay covers only folded tournaments");
        Some((fold, overlay))
    }

    /// Every reachable tournament, parents before children.
    pub fn reachable(&self) -> impl Iterator<Item = (&TournamentFold, &TournamentOverlay)> {
        self.fold
            .tournaments()
            .filter_map(|tf| self.overlay.get(&tf.address).map(|ov| (tf, ov)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tournament::fold::{EventKind, TournamentEvent};

    fn digest(byte: u8) -> Digest {
        Digest::from_digest(&[byte; 32]).unwrap()
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn bare_overlay() -> TournamentOverlay {
        TournamentOverlay {
            max_level: 3,
            log2_stride: 44,
            log2_stride_count: 48,
            base_cycle: U256::ZERO,
            winner: None,
            can_be_eliminated: false,
            clocks: HashMap::new(),
            live_matches: HashMap::new(),
        }
    }

    /// Reachability IS overlay membership: the iterator walks
    /// discovery order and silently skips tournaments the overlay
    /// never covered, and point lookups on them answer None - the
    /// contract the GC's sweep and the Hero's descent both lean on.
    #[test]
    fn dispute_state_serves_only_the_overlaid() {
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

        // Overlay covers the root only: the inner is history.
        let mut overlay = HashMap::new();
        overlay.insert(root, bare_overlay());
        let dispute = DisputeState { fold, overlay };

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
}
