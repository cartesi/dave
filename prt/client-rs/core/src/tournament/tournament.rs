//! This module defines the structs that are used for the interacting to tournaments

use crate::machine::MachineCommitment;

use alloy::primitives::{Address, B256};
use cartesi_dave_merkle::Digest;
use cartesi_machine::types::Hash;
use ruint::aliases::U256;
use std::{collections::HashMap, sync::Arc};

pub type TournamentStateMap = HashMap<Address, TournamentState>;
pub type CommitmentMap = HashMap<Address, MachineCommitment>;

//// Struct used to identify a match.
// #[derive(Clone, Copy, Debug)]
// pub struct MatchID {
//     pub commitment_one: Digest,
//     pub commitment_two: Digest,
// }
//
// impl MatchID {
//     pub fn hash(&self) -> alloy::primitives::B256 {
//         self.commitment_one.join(&self.commitment_two).into()
//     }
// }

/// Struct used to communicate the state of a commitment.
#[derive(Clone, Debug)]
pub struct CommitmentState {
    pub root_hash: Digest,
    pub clock: ClockState,
}

#[derive(Clone, Debug)]
pub enum ClockState {
    Stopped { allowance: u64 },
    Ticking { deadline: u64, allowance: u64 },
    Dead { since: u64 },
}

impl ClockState {
    pub fn new(block: u64, start_time: u64, allowance: u64) -> Self {
        assert!(block >= start_time);

        if start_time == 0 {
            Self::Stopped { allowance }
        } else if start_time + allowance > block {
            Self::Ticking {
                deadline: start_time + allowance,
                allowance: allowance - (block - start_time),
            }
        } else {
            Self::Dead {
                since: start_time + allowance,
            }
        }
    }
}

// impl ClockState {
//     pub fn has_time(&self) -> bool {
//         match self {
//             ClockState::Stopped { allowance, since } => true,
//             ClockState::Ticking { allowance, since } => self.start_instant + allowance > since,
//             ClockState::Dead { since } => false,
//         }
//         // if self.start_instant == 0 {
//         //     true
//         // } else {
//         //     self.deadline() > self.block_number
//         // }
//     }
//
//     pub fn time_since_timeout(&self) -> u64 {
//         if self.start_instant == 0 {
//             0
//         } else {
//             self.block_number - self.deadline()
//         }
//     }
//
//     // deadline of clock if it's ticking
//     fn deadline(&self) -> u64 {}
// }

// impl std::fmt::Display for ClockState {
//     fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
//         if self.start_instant == 0 {
//             write!(f, "clock paused, {} blocks left", self.allowance)
//         } else {
//             let time_elapsed = self.block_number - self.start_instant;
//             if self.allowance >= time_elapsed {
//                 write!(
//                     f,
//                     "clock ticking, {} blocks left",
//                     self.allowance - time_elapsed
//                 )
//             } else {
//                 write!(
//                     f,
//                     "clock ticking, {} blocks overdue",
//                     time_elapsed - self.allowance
//                 )
//             }
//         }
//     }
// }

/// Struct used to communicate the state of a tournament.
#[derive(Clone, Debug)]
pub struct TournamentState {
    pub address: Address,
    pub args: TournamentArgs,
    pub commitments_joined: HashMap<Digest, Arc<CommitmentState>>,
    pub status: TournamentStatus,
}

impl TournamentState {
    fn is_root(&self) -> bool {
        self.args.level == 0
    }
}

#[derive(Clone, Debug)]
pub struct TournamentArgs {
    pub level: u8,
    pub start_metacycle: U256,
    pub log2_stride: u64,
    pub log2_stride_count: u64,
}

#[derive(Clone, Debug)]
pub enum TournamentStatus {
    Finished {
        winner_commitment: Digest,
        final_state: cartesi_machine::types::Hash,
    },

    Dead,

    Ongoing {
        matches: Vec<Arc<MatchState>>,
    },
}

/// Struct used to communicate the state of a match.
#[derive(Clone, Debug)]
pub struct MatchState {
    pub commitment_one: Arc<CommitmentState>,
    pub commitment_two: Arc<CommitmentState>,
    pub status: MatchStatus,
}

impl MatchState {
    pub fn id(&self) -> Digest {
        self.commitment_one
            .root_hash
            .join(&self.commitment_two.root_hash)
    }
}

impl From<MatchState> for cartesi_prt_contracts::tournament::Match::Id {
    fn from(match_id: MatchState) -> Self {
        cartesi_prt_contracts::tournament::Match::Id {
            commitmentOne: match_id.commitment_one.root_hash.into(),
            commitmentTwo: match_id.commitment_two.root_hash.into(),
        }
    }
}

impl From<MatchState> for cartesi_prt_contracts::nonleaftournament::Match::Id {
    fn from(match_id: MatchState) -> Self {
        cartesi_prt_contracts::nonleaftournament::Match::Id {
            commitmentOne: match_id.commitment_one.root_hash.into(),
            commitmentTwo: match_id.commitment_two.root_hash.into(),
        }
    }
}

impl From<MatchState> for cartesi_prt_contracts::leaftournament::Match::Id {
    fn from(match_id: MatchState) -> Self {
        cartesi_prt_contracts::leaftournament::Match::Id {
            commitmentOne: match_id.commitment_one.root_hash.into(),
            commitmentTwo: match_id.commitment_two.root_hash.into(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Divergence {
    pub agree: Hash,
    pub p1_disagree: Hash,
    pub p2_disagree: Hash,
    pub agree_metacycle: U256,
}

#[derive(Clone, Debug)]
pub enum MatchStatus {
    Ongoing {
        other_parent: Digest,
        left_node: Digest,
        right_node: Digest,
        current_height: u64,
    },

    FinishedLeaf {
        divergence: Divergence,
    },

    FinishedNonLeaf {
        divergence: Divergence,
        inner_tournament: Box<TournamentState>,
    },
}
