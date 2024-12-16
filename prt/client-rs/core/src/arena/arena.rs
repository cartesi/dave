//! This module defines the structs that are used for the interacting to tournaments

use crate::machine::MachineCommitment;

use alloy::primitives::Address;
use cartesi_dave_merkle::Digest;
use ruint::aliases::U256;
use std::collections::HashMap;

pub type TournamentStateMap = HashMap<Address, TournamentState>;
pub type CommitmentMap = HashMap<Address, MachineCommitment>;

/// Struct used to identify a match.
#[derive(Clone, Copy)]
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

impl From<MatchID> for cartesi_prt_contracts::nonleaftournament::Match::Id {
    fn from(match_id: MatchID) -> Self {
        cartesi_prt_contracts::nonleaftournament::Match::Id {
            commitmentOne: match_id.commitment_one.into(),
            commitmentTwo: match_id.commitment_two.into(),
        }
    }
}

impl From<MatchID> for cartesi_prt_contracts::leaftournament::Match::Id {
    fn from(match_id: MatchID) -> Self {
        cartesi_prt_contracts::leaftournament::Match::Id {
            commitmentOne: match_id.commitment_one.into(),
            commitmentTwo: match_id.commitment_two.into(),
        }
    }
}

/// Struct used to communicate the state of a commitment.
#[derive(Clone, Copy)]
pub struct CommitmentState {
    pub clock: ClockState,
    pub final_state: Digest,
    pub latest_match: Option<usize>,
}

/// Struct used to communicate the state of a clock.
#[derive(Clone, Copy)]
pub struct ClockState {
    pub allowance: u64,
    pub start_instant: u64,
    pub block_number: u64,
}

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
            self.block_number - self.deadline()
        }
    }

    // deadline of clock if it's ticking
    fn deadline(&self) -> u64 {
        self.start_instant + self.allowance
    }
}

impl std::fmt::Display for ClockState {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.start_instant == 0 {
            write!(f, "clock paused, {} blocks left", self.allowance)
        } else {
            let time_elapsed = self.block_number - self.start_instant;
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
#[derive(Clone, PartialEq)]
pub enum TournamentWinner {
    Root(Digest, Digest),
    Inner(Digest, Digest),
}

/// Struct used to communicate the state of a tournament.
#[derive(Clone, Default)]
pub struct TournamentState {
    pub address: Address,
    pub base_big_cycle: u64,
    pub level: u64,
    pub log2_stride: u64,
    pub log2_stride_count: u64,
    pub max_level: u64,
    pub parent: Option<Address>,
    pub commitment_states: HashMap<Digest, CommitmentState>,
    pub matches: Vec<MatchState>,
    pub winner: Option<TournamentWinner>,
}

impl TournamentState {
    pub fn new_root(address: Address) -> Self {
        TournamentState {
            address,
            ..Default::default()
        }
    }

    pub fn new_inner(address: Address, level: u64, base_big_cycle: u64, parent: Address) -> Self {
        TournamentState {
            address,
            base_big_cycle,
            level: level + 1,
            parent: Some(parent),
            ..Default::default()
        }
    }
}

/// Struct used to communicate the state of a match.
#[derive(Clone, Copy)]
pub struct MatchState {
    pub id: MatchID,
    pub other_parent: Digest,
    pub left_node: Digest,
    pub right_node: Digest,
    pub running_leaf_position: U256,
    pub current_height: u64,
    pub leaf_cycle: U256,
    pub base_big_cycle: u64,
    pub tournament_address: Address,
    pub inner_tournament: Option<Address>,
}
