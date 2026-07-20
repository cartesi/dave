//! The Hero (the paper's name for the honest validator) fights the
//! dispute: every tree node its tick needs - level roots, bisection
//! children, seal and join proofs - is a quartet query against the
//! [`DisputeSource`], and the quartet cache in the node database is
//! the restartable dispute state. Turn taking is positional: the Match
//! contract's runningLeafPosition is the leftmost leaf of the contested
//! node, so the node to open is a coordinate computation, not a tree
//! search. Transition proofs (win_leaf_match) ride the ruler's proving
//! verbs. [`gc::GarbageCollector`] sweeps timed-out matches and dead
//! inner tournaments.

pub mod error;
pub mod gc;

use std::sync::Arc;

use crate::hero::error::Result;
use ::log::{debug, error, info};
use alloy::primitives::{Address, U256};
use async_recursion::async_recursion;

use crate::merkle::{Digest, MerkleProof};
use crate::{
    chain::Chain,
    engine::{DisputeSource, LevelCoords, Positioner, Quartet, RulerFactory, stf::ProvingStf},
    hero::gc::GarbageCollector,
    storage::Storage,
    tournament::{
        ArenaSender, DisputeState, MatchLive, StateReader, TournamentOverlay, TournamentWinner,
        fold::{MatchFold, TournamentFold},
    },
};

#[derive(Debug, PartialEq)]
pub enum TournamentResult {
    Lost,
    Running,
    Won,
}

/// One tournament level's commitment, as the Hero sees it: where
/// the tree sits, its root, and the state its first leaf builds on
/// (the implicit hash).
#[derive(Debug, Clone)]
struct LevelCommitment {
    coords: LevelCoords,
    root: Digest,
    initial_hash: Digest,
}

/// Generic over the ruler factory so the react loop runs under the
/// toy in unit tests; production is the default parameter, and only
/// the engine (DisputeSource::on_store) knows how to assemble itself
/// from storage.
pub struct Hero<AS: ArenaSender, F: RulerFactory = Positioner> {
    arena_sender: Arc<AS>,
    source: DisputeSource<F>,
    epoch: u64,
    /// Hash of the epoch's initial snapshot: the root level's implicit
    /// hash, and the anchor the root tournament was deployed with.
    epoch_initial_hash: Digest,
    root_tournament: Address,
    reader: StateReader,
    gc: GarbageCollector<AS>,
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

        // The epoch start's row hash IS the machine's root hash (the
        // CAS key): the root level's implicit hash, and the anchor
        // the root tournament was deployed with.
        let epoch_initial_hash: Digest = Digest::from_digest(
            &storage
                .snapshot_hash(epoch_number, 0)?
                .expect("snapshot is inserted atomically with settlement info"),
        )
        .map_err(anyhow::Error::from)?;

        // The reader persists finalized tournament events (fold phase
        // 2) through its own connection to the shared database, like
        // every other writer role.
        let reader_storage = Storage::new(storage.state_dir())?;

        // One facade serves both tree material and machine
        // positioning (proof witnesses, nested-tournament entry); it
        // assembles its whole working set from storage.
        let source = DisputeSource::on_store(storage, epoch_number, work_dir.join("engine"))?;

        let reader = StateReader::new(chain, block_created_number, reader_storage)?;
        let gc = GarbageCollector::new(arena_sender.clone(), root_tournament);
        Ok(Self {
            arena_sender,
            source,
            epoch: epoch_number,
            epoch_initial_hash,
            root_tournament,
            reader,
            gc,
        })
    }
}

impl<AS: ArenaSender, F: RulerFactory + Send> Hero<AS, F>
where
    F::S: ProvingStf,
{
    pub async fn tick(&mut self) -> Result<TournamentResult> {
        let dispute = self.reader.fetch_from_root(self.root_tournament).await?;

        self.gc.tick(&dispute).await?;
        self.react_tournament(
            None,
            self.epoch_initial_hash,
            self.root_tournament,
            &dispute,
        )
        .await
    }

    /// This level's commitment: root from the source, coordinates from
    /// the tournament's overlay, implicit hash from the caller (the
    /// epoch's initial state at the root, the sealed agree state for
    /// inners).
    fn level_commitment(
        &mut self,
        overlay: &TournamentOverlay,
        initial_hash: Digest,
    ) -> Result<LevelCommitment> {
        let coords = LevelCoords::new(
            self.epoch,
            overlay.base_cycle,
            overlay.log2_stride,
            overlay.log2_stride_count,
        );
        let root = self.source.node(&coords.root())?;
        Ok(LevelCommitment {
            coords,
            root,
            initial_hash,
        })
    }

    #[async_recursion]
    async fn react_tournament<'a>(
        &mut self,
        parent: Option<&'a LevelCommitment>,
        initial_hash: Digest,
        tournament_address: Address,
        dispute: &DisputeState,
    ) -> Result<TournamentResult> {
        info!("Enter tournament at address: {}", tournament_address);
        let (tournament, overlay) = dispute
            .tournament(&tournament_address)
            .expect("the hero only descends into reachable tournaments");

        let commitment = self.level_commitment(overlay, initial_hash)?;

        if let Some(winner) = &overlay.winner {
            match winner {
                TournamentWinner::Root(winner_commitment, winner_state) => {
                    info!(
                        "tournament finished, winner commitment: {}, state hash: {}",
                        winner_commitment, winner_state,
                    );
                    if commitment.root == *winner_commitment {
                        info!("hero won tournament {}", tournament.address);
                        return Ok(TournamentResult::Won);
                    } else {
                        error!("hero lost tournament {}", tournament.address);
                        return Ok(TournamentResult::Lost);
                    }
                }
                TournamentWinner::Inner(parent_commitment, _) => {
                    let parent = parent.expect("inner tournament without a parent level");
                    if *parent_commitment != parent.root {
                        error!("hero lost tournament {}", tournament.address);
                        return Ok(TournamentResult::Lost);
                    } else {
                        info!(
                            "win tournament {} of level {} for commitment {}",
                            tournament.address, tournament.level, commitment.root,
                        );
                        let (left, right) = self.source.children(&parent.coords.root())?;
                        let (parent_address, _) = tournament
                            .parent
                            .expect("inner tournament without a parent");
                        self.arena_sender
                            .win_inner_match(parent_address, tournament.address, left, right)
                            .await?;

                        return Ok(TournamentResult::Running);
                    }
                }
            }
        }

        match tournament.commitments.get(&commitment.root) {
            Some(ours) => {
                let clock = overlay
                    .clocks
                    .get(&commitment.root)
                    .expect("every joined commitment carries a clock");
                info!("{}", clock);

                // The fold indexes all matches; a commitment fights at
                // most one live match, so the latest one is either it
                // or history.
                let live_match = ours
                    .latest_match
                    .map(|i| &tournament.matches[i])
                    .filter(|m| m.is_live());
                match live_match {
                    Some(m) => {
                        let live = overlay
                            .live_matches
                            .get(&m.id.hash())
                            .expect("every live match carries an overlay");
                        self.react_match(m, live, &commitment, tournament, overlay, dispute)
                            .await?;
                    }
                    None => info!("no match found for commitment: {}", commitment.root),
                }
            }
            None => {
                self.join_tournament_if_needed(tournament, &commitment)
                    .await?;
            }
        }

        Ok(TournamentResult::Running)
    }

    async fn join_tournament_if_needed(
        &mut self,
        tournament: &TournamentFold,
        commitment: &LevelCommitment,
    ) -> Result<()> {
        let (left, right) = self.source.children(&commitment.coords.root())?;
        let proof_last = self.source.prove_last(&commitment.coords)?;

        info!(
            "join tournament {} of level {} with commitment {}",
            tournament.address, tournament.level, commitment.root,
        );

        // Get the bond value required for joining the tournament
        let bond_value = self.arena_sender.bond_value(tournament.address).await?;

        self.arena_sender
            .join_tournament(tournament.address, &proof_last, left, right, bond_value)
            .await?;

        Ok(())
    }

    /// The node a running match contests, and whether it is ours to
    /// open: the contract walks otherParent down one commitment tree,
    /// and it is our turn exactly when the node at that position of
    /// our tree is otherParent.
    fn contested_node(
        &mut self,
        live: &MatchLive,
        commitment: &LevelCommitment,
    ) -> Result<Option<Quartet>> {
        let quartet = commitment
            .coords
            .node(live.current_height, live.running_leaf_position);
        if self.source.node(&quartet)? == live.other_parent {
            Ok(Some(quartet))
        } else {
            Ok(None)
        }
    }

    #[async_recursion]
    async fn react_match<'a>(
        &mut self,
        match_fold: &'a MatchFold,
        live: &'a MatchLive,
        commitment: &'a LevelCommitment,
        tournament: &'a TournamentFold,
        overlay: &'a TournamentOverlay,
        dispute: &DisputeState,
    ) -> Result<()> {
        info!("Enter match at HEIGHT: {}", live.current_height);

        self.win_timeout_match(match_fold, commitment, tournament, overlay)
            .await?;

        if live.current_height == 0 {
            self.react_sealed_match(match_fold, live, commitment, tournament, overlay, dispute)
                .await?;
        } else if live.current_height == 1 {
            self.react_unsealed_match(match_fold, live, commitment, tournament, overlay)
                .await?;
        } else {
            self.react_running_match(match_fold, live, commitment, tournament)
                .await?;
        }
        Ok(())
    }

    async fn win_timeout_match(
        &mut self,
        match_fold: &MatchFold,
        commitment: &LevelCommitment,
        tournament: &TournamentFold,
        overlay: &TournamentOverlay,
    ) -> Result<()> {
        let opponent = if commitment.root == match_fold.id.commitment_one {
            match_fold.id.commitment_two
        } else {
            match_fold.id.commitment_one
        };
        let opponent_clock = overlay
            .clocks
            .get(&opponent)
            .expect("every joined commitment carries a clock");

        if !opponent_clock.has_time() {
            let (left, right) = self.source.children(&commitment.coords.root())?;

            info!(
                "win match by timeout in tournament {} of level {} for commitment {}",
                tournament.address, tournament.level, commitment.root,
            );

            self.arena_sender
                .win_timeout_match(tournament.address, match_fold.id, left, right)
                .await?;
        }
        Ok(())
    }

    #[async_recursion]
    async fn react_sealed_match<'a>(
        &mut self,
        match_fold: &'a MatchFold,
        live: &'a MatchLive,
        commitment: &'a LevelCommitment,
        tournament: &'a TournamentFold,
        overlay: &'a TournamentOverlay,
        dispute: &DisputeState,
    ) -> Result<()> {
        if tournament.level == (overlay.max_level - 1) {
            let (left, right) = self.source.children(&commitment.coords.root())?;

            let proof = {
                // Position on the disputed leaf (a snapshot resume
                // plus advance), check the chain-anchored agree
                // state, and prove the one transition.
                let mut ruler = self.source.machine_at(live.leaf_cycle)?;
                assert_eq!(
                    ruler.state_hash()?,
                    live.other_parent,
                    "positioned machine diverges from the on-chain agree state"
                );
                ruler.prove_transition()?
            };

            info!(
                "win leaf match in tournament {} of level {} for commitment {}, proof size {}",
                tournament.address,
                tournament.level,
                commitment.root,
                proof.0.len()
            );
            self.arena_sender
                .win_leaf_match(tournament.address, match_fold.id, left, right, proof.0)
                .await?;
        } else {
            // The sealed match's otherParent is the agreed state the
            // inner level builds on: its implicit hash, chain-anchored.
            self.react_tournament(
                Some(commitment),
                live.other_parent,
                match_fold
                    .inner_tournament
                    .expect("sealed inner match without its tournament"),
                dispute,
            )
            .await?;
        }

        Ok(())
    }

    async fn react_unsealed_match(
        &mut self,
        match_fold: &MatchFold,
        live: &MatchLive,
        commitment: &LevelCommitment,
        tournament: &TournamentFold,
        overlay: &TournamentOverlay,
    ) -> Result<()> {
        let Some(contested) = self.contested_node(live, commitment)? else {
            debug!("not my turn to react");
            return Ok(());
        };
        let (left, right) = self.source.children(&contested)?;

        let running_leaf_position = {
            if left != live.left_node {
                // disagree on left
                live.running_leaf_position
            } else {
                // disagree on right
                live.running_leaf_position + U256::ONE
            }
        };

        let agree_state_proof = if running_leaf_position.is_zero() {
            MerkleProof::leaf(commitment.initial_hash, U256::ZERO)
        } else {
            self.source
                .prove_leaf(&commitment.coords, running_leaf_position - U256::ONE)?
        };

        if tournament.level == (overlay.max_level - 1) {
            info!(
                "seal leaf match in tournament {} of level {} for commitment {}",
                tournament.address, tournament.level, commitment.root,
            );
            self.arena_sender
                .seal_leaf_match(
                    tournament.address,
                    match_fold.id,
                    left,
                    right,
                    &agree_state_proof,
                )
                .await?;
        } else {
            info!(
                "seal inner match in tournament {} of level {} for commitment {}",
                tournament.address, tournament.level, commitment.root,
            );
            self.arena_sender
                .seal_inner_match(
                    tournament.address,
                    match_fold.id,
                    left,
                    right,
                    &agree_state_proof,
                )
                .await?;
        }
        Ok(())
    }

    async fn react_running_match(
        &mut self,
        match_fold: &MatchFold,
        live: &MatchLive,
        commitment: &LevelCommitment,
        tournament: &TournamentFold,
    ) -> Result<()> {
        let Some(contested) = self.contested_node(live, commitment)? else {
            debug!("not my turn to react");
            return Ok(());
        };
        let (left, right) = self.source.children(&contested)?;
        let (left_child, right_child) = contested.children().expect("running match above leaves");

        let (new_left, new_right) = if left != live.left_node {
            debug!("going down to the left");
            self.source.children(&left_child)?
        } else {
            debug!("going down to the right");
            self.source.children(&right_child)?
        };

        info!(
            "advance match with current height {} in tournament {} of level {} for commitment {}",
            live.current_height, tournament.address, tournament.level, commitment.root,
        );
        self.arena_sender
            .advance_match(
                tournament.address,
                match_fold.id,
                left,
                right,
                new_left,
                new_right,
            )
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    //! The Hero's decision table, unit-tested chain-free: hand-built
    //! DisputeStates (the fold fed synthetic events, the overlay
    //! written directly) over the toy engine source, with a recording
    //! arena in place of the chain. Every arena verb the react loop
    //! can choose is pinned here; the e2e suites remain the outer net
    //! that checks the chain agrees with these choices.

    use super::*;
    use crate::engine::spec::{S_SMALL, toy_source};
    use crate::engine::{ToyFactory, ToyInput, ToyOutcome, ToyStf};
    use crate::merkle::MerkleProof;
    use crate::tournament::fold::{EventKind, Fold, TournamentEvent};
    use crate::tournament::{ClockState, MachineProof, MatchID};
    use alloy::providers::{Provider, ProviderBuilder};
    use async_trait::async_trait;
    use std::collections::HashMap;

    fn addr(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn dg(byte: u8) -> Digest {
        Digest::from_digest(&[byte; 32]).unwrap()
    }

    /// Every arena verb the Hero can choose, with the arguments the
    /// tests pin.
    #[derive(Debug, Clone, PartialEq)]
    enum ArenaCall {
        Join {
            tournament: Address,
            left: Digest,
            right: Digest,
        },
        Advance {
            tournament: Address,
            id: Digest,
            left: Digest,
            right: Digest,
            new_left: Digest,
            new_right: Digest,
        },
        SealInner {
            tournament: Address,
            id: Digest,
            agree_position: U256,
        },
        SealLeaf {
            tournament: Address,
            id: Digest,
            agree_position: U256,
        },
        WinInner {
            tournament: Address,
            child: Address,
        },
        WinTimeout {
            tournament: Address,
            id: Digest,
        },
        WinLeaf {
            tournament: Address,
            id: Digest,
            proof: Vec<u8>,
        },
        EliminateMatch {
            tournament: Address,
            id: Digest,
        },
        EliminateInner {
            tournament: Address,
            child: Address,
        },
    }

    #[derive(Default)]
    struct RecordingArena {
        calls: std::sync::Mutex<Vec<ArenaCall>>,
    }

    impl RecordingArena {
        fn push(&self, call: ArenaCall) {
            self.calls.lock().unwrap().push(call);
        }

        fn take(&self) -> Vec<ArenaCall> {
            std::mem::take(&mut *self.calls.lock().unwrap())
        }
    }

    #[async_trait]
    impl ArenaSender for RecordingArena {
        async fn join_tournament(
            &self,
            tournament: Address,
            _proof: &MerkleProof,
            left: Digest,
            right: Digest,
            _bond_value: U256,
        ) -> Result<()> {
            self.push(ArenaCall::Join {
                tournament,
                left,
                right,
            });
            Ok(())
        }

        async fn advance_match(
            &self,
            tournament: Address,
            match_id: MatchID,
            left: Digest,
            right: Digest,
            new_left: Digest,
            new_right: Digest,
        ) -> Result<()> {
            self.push(ArenaCall::Advance {
                tournament,
                id: match_id.hash(),
                left,
                right,
                new_left,
                new_right,
            });
            Ok(())
        }

        async fn seal_inner_match(
            &self,
            tournament: Address,
            match_id: MatchID,
            _left: Digest,
            _right: Digest,
            agree_proof: &MerkleProof,
        ) -> Result<()> {
            self.push(ArenaCall::SealInner {
                tournament,
                id: match_id.hash(),
                agree_position: agree_proof.position,
            });
            Ok(())
        }

        async fn win_inner_match(
            &self,
            tournament: Address,
            child: Address,
            _left: Digest,
            _right: Digest,
        ) -> Result<()> {
            self.push(ArenaCall::WinInner { tournament, child });
            Ok(())
        }

        async fn win_timeout_match(
            &self,
            tournament: Address,
            match_id: MatchID,
            _left: Digest,
            _right: Digest,
        ) -> Result<()> {
            self.push(ArenaCall::WinTimeout {
                tournament,
                id: match_id.hash(),
            });
            Ok(())
        }

        async fn seal_leaf_match(
            &self,
            tournament: Address,
            match_id: MatchID,
            _left: Digest,
            _right: Digest,
            agree_proof: &MerkleProof,
        ) -> Result<()> {
            self.push(ArenaCall::SealLeaf {
                tournament,
                id: match_id.hash(),
                agree_position: agree_proof.position,
            });
            Ok(())
        }

        async fn win_leaf_match(
            &self,
            tournament: Address,
            match_id: MatchID,
            _left: Digest,
            _right: Digest,
            proof: MachineProof,
        ) -> Result<()> {
            self.push(ArenaCall::WinLeaf {
                tournament,
                id: match_id.hash(),
                proof,
            });
            Ok(())
        }

        async fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> Result<()> {
            self.push(ArenaCall::EliminateMatch {
                tournament,
                id: match_id.hash(),
            });
            Ok(())
        }

        async fn eliminate_inner_tournament(
            &self,
            tournament: Address,
            child: Address,
        ) -> Result<()> {
            self.push(ArenaCall::EliminateInner { tournament, child });
            Ok(())
        }

        async fn bond_value(&self, _tournament: Address) -> Result<U256> {
            Ok(U256::from(7))
        }
    }

    const ROOT: fn() -> Address = || addr(0xA1);
    const INNER: fn() -> Address = || addr(0xB2);

    fn script() -> Vec<ToyInput> {
        vec![ToyInput {
            big_cycles: vec![2, 1],
            outcome: ToyOutcome::Accept,
        }]
    }

    /// Two-level geometry over S_SMALL (ruler 2^7): the root at
    /// stride 2^3 height 4, inners at stride 2^0 height 3.
    const TWO_LEVEL: (u64, (u64, u64), (u64, u64)) = (2, (3, 4), (0, 3));
    /// One-level geometry: the root IS the leaf level, whole ruler at
    /// uarch granularity.
    const ONE_LEVEL: (u64, (u64, u64), (u64, u64)) = (1, (0, 7), (0, 0));

    fn level0(geometry: (u64, (u64, u64), (u64, u64))) -> LevelCoords {
        let (stride, height) = geometry.1;
        LevelCoords::new(0, U256::ZERO, stride, height)
    }

    fn overlay_for(
        geometry: (u64, (u64, u64), (u64, u64)),
        level: u64,
        base_cycle: U256,
    ) -> TournamentOverlay {
        let (stride, height) = if level == 0 { geometry.1 } else { geometry.2 };
        TournamentOverlay {
            max_level: geometry.0,
            log2_stride: stride,
            log2_stride_count: height,
            base_cycle,
            winner: None,
            can_be_eliminated: false,
            clocks: HashMap::new(),
            live_matches: HashMap::new(),
        }
    }

    fn alive_clock() -> ClockState {
        ClockState {
            allowance: 100,
            start_instant: 0,
            block_number: 0,
        }
    }

    /// Timed out so long ago that even elimination's overshoot
    /// condition holds against a 100-block allowance.
    fn dead_clock() -> ClockState {
        ClockState {
            allowance: 5,
            start_instant: 1,
            block_number: 1000,
        }
    }

    fn ev(tournament: Address, kind: EventKind) -> TournamentEvent {
        TournamentEvent {
            tournament,
            block: 1,
            kind,
        }
    }

    fn joined(root: Digest) -> EventKind {
        EventKind::CommitmentJoined {
            root,
            final_state: dg(0xFF),
        }
    }

    /// Expected node hashes come from an independent toy source: the
    /// same script, a fresh cache.
    fn ref_node(level: &LevelCoords, height: u64, position: U256) -> Digest {
        let mut source = toy_source(S_SMALL, &script());
        source.node(&level.node(height, position)).unwrap()
    }

    fn ref_children(level: &LevelCoords, height: u64, position: U256) -> (Digest, Digest) {
        let mut source = toy_source(S_SMALL, &script());
        source.children(&level.node(height, position)).unwrap()
    }

    fn toy_hero() -> (Hero<RecordingArena, ToyFactory>, Arc<RecordingArena>) {
        let arena = Arc::new(RecordingArena::default());
        let source = toy_source(S_SMALL, &script());
        // Never dialed: react_tournament takes the state as an
        // argument; only tick() fetches (and only tick() would touch
        // the reader's event-log storage).
        let chain = crate::chain::Chain::new(
            ProviderBuilder::new()
                .connect_http("http://127.0.0.1:1".parse().unwrap())
                .erased(),
            vec![],
        );
        let reader = StateReader::new(chain, 0, crate::engine::spec::toy_storage(S_SMALL)).unwrap();
        let gc = GarbageCollector::new(arena.clone(), ROOT());
        let hero = Hero {
            arena_sender: arena.clone(),
            source,
            epoch: 0,
            epoch_initial_hash: ToyStf::hash_of(0),
            root_tournament: ROOT(),
            reader,
            gc,
        };
        (hero, arena)
    }

    /// A root tournament where our commitment and a sybil's fight one
    /// live match, positioned by the caller. Returns the dispute and
    /// the match id hash.
    fn dispute_with_match(
        geometry: (u64, (u64, u64), (u64, u64)),
        ours: Digest,
        live: MatchLive,
    ) -> (DisputeState, Digest) {
        let sybil = dg(0x51);
        let id = MatchID {
            commitment_one: ours,
            commitment_two: sybil,
        };
        let id_hash = id.hash();

        let mut fold = Fold::new(ROOT());
        fold.apply(&ev(ROOT(), joined(ours))).unwrap();
        fold.apply(&ev(ROOT(), joined(sybil))).unwrap();
        fold.apply(&ev(
            ROOT(),
            EventKind::MatchCreated {
                one: ours,
                two: sybil,
                left_of_two: dg(0x52),
            },
        ))
        .unwrap();

        let mut ov = overlay_for(geometry, 0, U256::ZERO);
        ov.clocks.insert(ours, alive_clock());
        ov.clocks.insert(sybil, alive_clock());
        ov.live_matches.insert(id_hash, live);

        let mut overlay = HashMap::new();
        overlay.insert(ROOT(), ov);
        (DisputeState { fold, overlay }, id_hash)
    }

    fn running_match(other_parent: Digest, left_node: Digest, current_height: u64) -> MatchLive {
        MatchLive {
            other_parent,
            left_node,
            right_node: dg(0x53),
            running_leaf_position: U256::ZERO,
            current_height,
            leaf_cycle: U256::ZERO,
        }
    }

    #[tokio::test]
    async fn joins_a_tournament_it_has_not_joined() {
        let (mut hero, arena) = toy_hero();
        let mut overlay = HashMap::new();
        overlay.insert(ROOT(), overlay_for(TWO_LEVEL, 0, U256::ZERO));
        let dispute = DisputeState {
            fold: Fold::new(ROOT()),
            overlay,
        };

        let result = hero
            .react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(result, TournamentResult::Running);
        let level = level0(TWO_LEVEL);
        let (left, right) = ref_children(&level, level.height, U256::ZERO);
        assert_eq!(
            arena.take(),
            vec![ArenaCall::Join {
                tournament: ROOT(),
                left,
                right
            }]
        );
    }

    #[tokio::test]
    async fn reports_the_root_verdict() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);

        for (winner, expected) in [
            (ours, TournamentResult::Won),
            (dg(0x66), TournamentResult::Lost),
        ] {
            let (mut hero, arena) = toy_hero();
            let mut ov = overlay_for(TWO_LEVEL, 0, U256::ZERO);
            ov.winner = Some(TournamentWinner::Root(winner, dg(0x09)));
            let mut overlay = HashMap::new();
            overlay.insert(ROOT(), ov);
            let dispute = DisputeState {
                fold: Fold::new(ROOT()),
                overlay,
            };

            let result = hero
                .react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
                .await
                .unwrap();
            assert_eq!(result, expected);
            assert_eq!(arena.take(), vec![]);
        }
    }

    #[tokio::test]
    async fn advances_when_it_is_our_turn() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        // The contract walked otherParent onto OUR node at height 2:
        // our turn. Its left disagrees with ours, so we descend left.
        let contested = ref_node(&level, 2, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        let (dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(contested, dg(0x66), 2));

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        let (left, right) = ref_children(&level, 2, U256::ZERO);
        let (new_left, new_right) = ref_children(&level, 1, U256::ZERO);
        assert_eq!(
            arena.take(),
            vec![ArenaCall::Advance {
                tournament: ROOT(),
                id: id_hash,
                left,
                right,
                new_left,
                new_right
            }]
        );
    }

    #[tokio::test]
    async fn descends_right_when_agreeing_on_the_left() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let contested = ref_node(&level, 2, U256::ZERO);
        let (left, right) = ref_children(&level, 2, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        // otherParent is ours and its left EQUALS ours: the
        // disagreement is on the right child.
        let (dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(contested, left, 2));

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        let (new_left, new_right) = ref_children(&level, 1, U256::from(2));
        assert_eq!(
            arena.take(),
            vec![ArenaCall::Advance {
                tournament: ROOT(),
                id: id_hash,
                left,
                right,
                new_left,
                new_right
            }]
        );
    }

    #[tokio::test]
    async fn waits_when_it_is_not_our_turn() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        // otherParent is not a node of our tree: the opponent moves.
        let (dispute, _) =
            dispute_with_match(TWO_LEVEL, ours, running_match(dg(0x99), dg(0x66), 2));

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(arena.take(), vec![]);
    }

    #[tokio::test]
    async fn seals_an_inner_match_at_height_one() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let contested = ref_node(&level, 1, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        // Divergence at position zero: the agree state is the level's
        // implicit hash, proved at position zero.
        let (dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(contested, dg(0x66), 1));

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(
            arena.take(),
            vec![ArenaCall::SealInner {
                tournament: ROOT(),
                id: id_hash,
                agree_position: U256::ZERO
            }]
        );
    }

    #[tokio::test]
    async fn seals_a_leaf_match_on_the_last_level() {
        let level = level0(ONE_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let contested = ref_node(&level, 1, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        let (dispute, id_hash) =
            dispute_with_match(ONE_LEVEL, ours, running_match(contested, dg(0x66), 1));

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(
            arena.take(),
            vec![ArenaCall::SealLeaf {
                tournament: ROOT(),
                id: id_hash,
                agree_position: U256::ZERO
            }]
        );
    }

    #[tokio::test]
    async fn proves_the_leaf_transition_by_shape() {
        // The three witness shapes prove_transition selects by
        // position: window start (feed + fused ustep), plain ustep,
        // and the closing slot (ustep + ureset + revert check). The
        // toy's inert markers make the selection visible.
        let cases: [(u64, &[u8]); 3] = [
            (0, b"toy-feed;toy-ustep;"),
            (1, b"toy-ustep;"),
            (7, b"toy-ustep;toy-ureset;toy-revert-check;"),
        ];

        for (position, expected_proof) in cases {
            let level = level0(ONE_LEVEL);
            let ours = ref_node(&level, level.height, U256::ZERO);
            // The chain-anchored agree state at the disputed leaf:
            // what the positioned prover must reproduce.
            let agree = ToyFactory {
                structure: S_SMALL,
                script: script(),
            }
            .ruler_at(U256::from(position))
            .unwrap()
            .state_hash()
            .unwrap();

            let (mut hero, arena) = toy_hero();
            let live = MatchLive {
                other_parent: agree,
                left_node: dg(0x66),
                right_node: dg(0x53),
                running_leaf_position: U256::ZERO,
                current_height: 0,
                leaf_cycle: U256::from(position),
            };
            let (dispute, id_hash) = dispute_with_match(ONE_LEVEL, ours, live);

            hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
                .await
                .unwrap();

            assert_eq!(
                arena.take(),
                vec![ArenaCall::WinLeaf {
                    tournament: ROOT(),
                    id: id_hash,
                    proof: expected_proof.to_vec()
                }],
                "shape at position {position}"
            );
        }
    }

    #[tokio::test]
    async fn wins_by_timeout_when_the_opponent_clock_dies() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        let (mut dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(dg(0x99), dg(0x66), 2));
        dispute
            .overlay
            .get_mut(&ROOT())
            .unwrap()
            .clocks
            .insert(dg(0x51), dead_clock());

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(
            arena.take(),
            vec![ArenaCall::WinTimeout {
                tournament: ROOT(),
                id: id_hash
            }]
        );
    }

    #[tokio::test]
    async fn descends_into_the_inner_tournament_and_wins_it() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        // The parent match sealed into an inner tournament whose
        // winner the chain already declared: our parent commitment.
        let (mut dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(dg(0x77), dg(0x66), 0));
        dispute
            .fold
            .apply(&ev(
                ROOT(),
                EventKind::NewInnerTournament {
                    match_id_hash: id_hash,
                    child: INNER(),
                },
            ))
            .unwrap();
        let mut inner_ov = overlay_for(TWO_LEVEL, 1, U256::ZERO);
        inner_ov.winner = Some(TournamentWinner::Inner(ours, dg(0x08)));
        dispute.overlay.insert(INNER(), inner_ov);

        let result = hero
            .react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(result, TournamentResult::Running);
        assert_eq!(
            arena.take(),
            vec![ArenaCall::WinInner {
                tournament: ROOT(),
                child: INNER()
            }]
        );
    }

    #[tokio::test]
    async fn idles_when_its_match_is_history() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let (mut hero, arena) = toy_hero();
        let (mut dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(dg(0x99), dg(0x66), 2));
        // The match resolved; the fold remembers it, nothing is live.
        dispute
            .fold
            .apply(&ev(
                ROOT(),
                EventKind::MatchDeleted {
                    match_id_hash: id_hash,
                    reason: crate::tournament::fold::MatchDeletionReason::Timeout,
                    winner: crate::tournament::fold::WinnerCommitment::One,
                },
            ))
            .unwrap();
        dispute
            .overlay
            .get_mut(&ROOT())
            .unwrap()
            .live_matches
            .clear();

        hero.react_tournament(None, ToyStf::hash_of(0), ROOT(), &dispute)
            .await
            .unwrap();

        assert_eq!(arena.take(), vec![]);
    }

    #[tokio::test]
    async fn gc_eliminates_a_match_both_of_whose_clocks_died() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let (hero, arena) = toy_hero();
        let (mut dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(dg(0x99), dg(0x66), 2));
        let clocks = &mut dispute.overlay.get_mut(&ROOT()).unwrap().clocks;
        clocks.insert(ours, dead_clock());
        clocks.insert(dg(0x51), dead_clock());

        hero.gc.tick(&dispute).await.unwrap();

        assert_eq!(
            arena.take(),
            vec![ArenaCall::EliminateMatch {
                tournament: ROOT(),
                id: id_hash
            }]
        );
    }

    #[tokio::test]
    async fn gc_eliminates_an_eliminable_inner_tournament() {
        let level = level0(TWO_LEVEL);
        let ours = ref_node(&level, level.height, U256::ZERO);
        let (hero, arena) = toy_hero();
        let (mut dispute, id_hash) =
            dispute_with_match(TWO_LEVEL, ours, running_match(dg(0x77), dg(0x66), 0));
        dispute
            .fold
            .apply(&ev(
                ROOT(),
                EventKind::NewInnerTournament {
                    match_id_hash: id_hash,
                    child: INNER(),
                },
            ))
            .unwrap();
        let mut inner_ov = overlay_for(TWO_LEVEL, 1, U256::ZERO);
        inner_ov.can_be_eliminated = true;
        dispute.overlay.insert(INNER(), inner_ov);

        hero.gc.tick(&dispute).await.unwrap();

        assert_eq!(
            arena.take(),
            vec![ArenaCall::EliminateInner {
                tournament: ROOT(),
                child: INNER()
            }]
        );
    }
}
