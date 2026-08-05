//! The tournament value types shared by the fold, the reader, and the
//! Hero, and the reader's product: [`DisputeState`], the dispute's
//! event-derived structure plus one disposable semantic observation.

use crate::merkle::Digest;
use alloy::primitives::Address;
#[cfg(test)]
use alloy::primitives::U256;
use std::collections::HashMap;

use crate::chain::ChainHead;
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
}
