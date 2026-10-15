//! Production Hero orchestration: observe, project, plan, prepare, and
//! yield the tick's wave contribution for the epoch manager to submit.

use std::{collections::HashMap, time::Instant};

use ::log::{debug, error, info};
use anyhow::{Result, ensure};

use crate::{
    chain::{Chain, ChainHead},
    engine::{DisputeSource, Positioner},
    fatal::Fatal,
    hero::{
        action::{PreparedArenaAction, prepare},
        context::{EpochAnchors, HeroContext},
        gc_planner::plan_gc,
        planner::{HeroDecision, HeroIntent, HeroTerminal, plan_hero},
    },
    merkle::Digest,
    provider::LaneRequest,
    storage::Storage,
    sync::ShutdownSignal,
    tournament::{
        StateReader,
        dispute::Dispute,
        domain::{GcIntent, TournamentStanding},
        observer::{read_bond, read_standings},
        sender,
    },
};
use alloy::primitives::Address;

/// One dispute tick's outcome and its optional lane request.
///
/// A tick yields at most one request: the Hero's action, or a cleanup when
/// the Hero waits.
#[derive(Clone, Debug)]
pub struct HeroTick {
    result: Option<HeroTerminal>,
    head: ChainHead,
    request: Option<LaneRequest>,
}

impl HeroTick {
    pub(crate) fn new(
        result: Option<HeroTerminal>,
        head: ChainHead,
        request: Option<LaneRequest>,
    ) -> Self {
        Self {
            result,
            head,
            request,
        }
    }

    /// The dispute's terminal result, or None while it runs.
    pub const fn result(&self) -> Option<HeroTerminal> {
        self.result
    }

    /// The latest head the result was observed at. Settlement reads its
    /// views there, so a won root and the staged winner describe one block.
    pub const fn head(&self) -> ChainHead {
        self.head
    }

    pub fn into_request(self) -> Option<LaneRequest> {
        self.request
    }
}

/// The production actor owns one epoch's real machine source.
pub struct Hero {
    source: DisputeSource<Positioner>,
    epoch: u64,
    anchors: EpochAnchors,
    root_tournament: Address,
    reader: StateReader,
    #[cfg(test)]
    reobservations: usize,
}

/// One observation: the latest foam, its standings, and the Hero's path
/// assembled on it, local commitments included.
struct Observation {
    head: ChainHead,
    foam: Dispute,
    standings: HashMap<Address, TournamentStanding>,
    context: HeroContext,
}

impl Hero {
    /// The node's Hero: its machine work stops once `shutdown` is
    /// requested, keeping what it stored for the restarted node.
    pub fn new(
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        mut storage: Storage,
        epoch_number: u64,
        shutdown: ShutdownSignal,
    ) -> Result<Self> {
        let engine_dir = storage.epoch_directory(epoch_number)?.join("engine");
        let mut hero = Self::build(
            chain,
            root_tournament,
            block_created_number,
            storage,
            epoch_number,
            engine_dir,
        )?;
        hero.source.stop_on(shutdown);
        Ok(hero)
    }

    /// The harness adversary: this actor over a test-only tail overlay.
    /// It needs its own engine directory, since a source's positioner
    /// clears the work directories it numbers.
    #[cfg(test)]
    pub(crate) fn with_tail(
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        storage: Storage,
        epoch_number: u64,
        engine_dir: std::path::PathBuf,
        tail: crate::engine::Tail,
    ) -> Result<Self> {
        let mut hero = Self::build(
            chain,
            root_tournament,
            block_created_number,
            storage,
            epoch_number,
            engine_dir,
        )?;
        hero.source.set_tail(tail);
        Ok(hero)
    }

    fn build(
        chain: Chain,
        root_tournament: Address,
        block_created_number: u64,
        mut storage: Storage,
        epoch_number: u64,
        engine_dir: std::path::PathBuf,
    ) -> Result<Self> {
        let initial_hash = Digest::from_digest(
            &storage
                .snapshot_hash(epoch_number, 0)?
                .expect("snapshot is inserted atomically with settlement info"),
        )?;
        let anchors = EpochAnchors {
            initial_hash,
            geometry: storage.sling_config()?.geometry,
        };
        let source = DisputeSource::on_store(storage, epoch_number, engine_dir)?;
        let reader = StateReader::new(chain, block_created_number);

        Ok(Self {
            source,
            epoch: epoch_number,
            anchors,
            root_tournament,
            reader,
            #[cfg(test)]
            reobservations: 0,
        })
    }

    /// Ticks whose observation was repeated after a build.
    #[cfg(test)]
    pub(crate) fn reobservations(&self) -> usize {
        self.reobservations
    }

    pub async fn tick(&mut self) -> Result<HeroTick> {
        let ticked = self.plan_tick().await;
        if let Err(error) = &ticked {
            self.reader.forget_contradicted_solid(error);
        }
        ticked
    }

    async fn plan_tick(&mut self) -> Result<HeroTick> {
        // The node's share of a response's time runs from reading the chain
        // through commitment builds (context assembly builds the local
        // material) and proving to submission; operators compare it with
        // the deployed budgets.
        let started = Instant::now();
        let trips = self.source.trips();
        let mut observed = self.observe().await?;
        if self.source.trips() != trips {
            // Assembly ran machine work (tens of minutes for a two-level
            // leaf) while the chain moved on: a child may have finalized for
            // the join, and the head may have left a pruned provider's state
            // window. Plan from a fresh observation, whose assembly reuses
            // the build. Once: act on it even if it built again.
            debug!("assembly ran machine work; observing again before planning");
            #[cfg(test)]
            {
                self.reobservations += 1;
            }
            observed = self.observe().await?;
        }
        let Observation {
            head: latest_head,
            foam,
            standings: foam_standings,
            context: foam_context,
        } = observed;
        let chain = self.reader.chain().clone();
        let foam_decision = plan_hero(foam_context.snapshot());

        // Joining commits to the epoch's computation. Latest may suppress a
        // join that is already mined or no longer possible, but only Solid may
        // supply its payload. All deadline-sensitive actions use Foam.
        let (context, decision, action_head) = if matches!(
            foam_decision,
            HeroDecision::Act(HeroIntent::Join { .. })
        ) {
            let (solid_head, solid) = self
                .reader
                .solid()
                .expect("fetch_from_root initializes Solid");
            let solid_standings = read_standings(&chain, solid, solid_head).await?;
            let solid_context = HeroContext::assemble(
                &chain,
                solid_head,
                self.epoch,
                &self.anchors,
                solid,
                &solid_standings,
                &mut self.source,
            )
            .await?;
            let solid_decision = plan_hero(solid_context.snapshot());
            if solid_decision != foam_decision {
                // Keep the lane empty while Solid catches up. A Foam cleanup
                // here could still be pending when the finalized join is due.
                debug!(
                    "latest proposed {foam_decision:?}, which Solid does not support exactly; retry next tick"
                );
                report_slow_tick(started, "the join waits for finality");
                return Ok(HeroTick::new(None, latest_head, None));
            }
            (solid_context, solid_decision, solid_head)
        } else {
            (foam_context, foam_decision, latest_head)
        };

        let mut result = None;
        let mut request = None;
        match decision {
            HeroDecision::Act(intent) => {
                let action = super::machine_work(|| prepare(intent, &context, &mut self.source))?;
                info!(
                    "prepared {intent:?} in {:.1?} (reads, builds and proving), observed at block {}",
                    started.elapsed(),
                    action_head.number
                );
                request = Some(request_prepared(&chain, action, action_head).await?);
            }
            HeroDecision::Wait(reason) => {
                if reason.missed() {
                    // Logged every tick, like a lost root: the commitment is
                    // no longer defended here, though a same-class commitment
                    // may still win a child.
                    error!(
                        "epoch {}: the local commitment missed an obligation and is no \
                         longer defended there: {reason:?}",
                        self.epoch
                    );
                } else {
                    debug!("Hero waits: {reason:?}");
                }
                report_slow_tick(started, format!("{reason:?}"));
                request = self.gc_request(&foam, &foam_standings, latest_head.number)?;
            }
            HeroDecision::Terminal(terminal) => {
                // The epoch manager logs the result, once per tick.
                result = Some(terminal);
            }
        }
        Ok(HeroTick::new(result, latest_head, request))
    }

    async fn observe(&mut self) -> Result<Observation> {
        let (head, foam) = self.reader.fetch_from_root(self.root_tournament).await?;
        // The previous epoch settled a state this node did not compute: a
        // divergence it lost, or a corrupt data directory. It cannot defend
        // this epoch, so it stops; it reached here only after the previous
        // epoch's refunds and sentry vote.
        let root = foam.root().descriptor();
        ensure!(
            root.initial_hash() == self.anchors.initial_hash,
            Fatal::terminal(format!(
                "epoch {}'s root tournament {} starts from {}, but this node computed {}: \
                 the chain settled a state this node did not compute",
                self.epoch,
                root.address(),
                root.initial_hash(),
                self.anchors.initial_hash,
            ))
        );
        let chain = self.reader.chain().clone();
        let standings = read_standings(&chain, &foam, head).await?;
        let context = HeroContext::assemble(
            &chain,
            head,
            self.epoch,
            &self.anchors,
            &foam,
            &standings,
            &mut self.source,
        )
        .await?;
        Ok(Observation {
            head,
            foam,
            standings,
            context,
        })
    }

    fn gc_request(
        &self,
        dispute: &Dispute,
        standings: &HashMap<Address, TournamentStanding>,
        at: u64,
    ) -> Result<Option<LaneRequest>> {
        let Some(intent) = plan_gc(dispute, standings, at)? else {
            return Ok(None);
        };
        info!("plan cleanup intent: {intent:?}");
        let provider = self.reader.chain().provider();
        Ok(Some(match intent {
            GcIntent::EliminateMatch {
                tournament,
                match_id,
            } => sender::eliminate_match(provider, tournament, match_id),
            GcIntent::EliminateChild {
                parent_tournament,
                child_tournament,
            } => sender::eliminate_inner_tournament(provider, parent_tournament, child_tournament),
        }))
    }
}

/// A tick that does local work without acting still spends the node's
/// time, most often a commitment build ahead of a join that waits for
/// finality; report it when it is not instant.
fn report_slow_tick(started: Instant, outcome: impl std::fmt::Display) {
    let elapsed = started.elapsed();
    if elapsed >= std::time::Duration::from_secs(1) {
        info!("Hero tick took {elapsed:.1?} without acting: {outcome}");
    }
}

/// The only production dispatch seam for a prepared Hero action. Matching one
/// enum value yields exactly one mutation request; no error path selects a
/// second verb from the same observation.
async fn request_prepared(
    chain: &Chain,
    action: PreparedArenaAction,
    head: ChainHead,
) -> Result<LaneRequest> {
    let provider = chain.provider();
    // These concise action markers are also synchronization points for the
    // crash-recovery e2e scenarios. Emit them as the request enters the
    // wave, immediately before the tick submits it.
    Ok(match action {
        PreparedArenaAction::Join {
            tournament,
            proof_last,
            left_child,
            right_child,
        } => {
            info!("submit Hero action: join tournament {tournament}");
            let bond = read_bond(chain, tournament, head).await?;
            sender::join_tournament(
                provider,
                tournament,
                &proof_last,
                left_child,
                right_child,
                bond,
            )
        }
        PreparedArenaAction::ClaimTimeout {
            tournament,
            match_id,
            left_node,
            right_node,
        } => {
            info!(
                "submit Hero action: claim timeout for match {} in tournament {tournament}",
                match_id.hash()
            );
            sender::win_timeout_match(provider, tournament, match_id, left_node, right_node)
        }
        PreparedArenaAction::Advance {
            tournament,
            match_id,
            left_node,
            right_node,
            new_left_node,
            new_right_node,
        } => {
            info!(
                "submit Hero action: advance match {} in tournament {tournament}",
                match_id.hash()
            );
            sender::advance_match(
                provider,
                tournament,
                match_id,
                left_node,
                right_node,
                new_left_node,
                new_right_node,
            )
        }
        PreparedArenaAction::SealLeaf {
            tournament,
            match_id,
            left_leaf,
            right_leaf,
            agree_state_proof,
        } => {
            info!(
                "submit Hero action: seal leaf match {} in tournament {tournament}",
                match_id.hash()
            );
            sender::seal_leaf_match(
                provider,
                tournament,
                match_id,
                left_leaf,
                right_leaf,
                &agree_state_proof,
            )
        }
        PreparedArenaAction::CreateChild {
            tournament,
            match_id,
            left_leaf,
            right_leaf,
            agree_state_proof,
        } => {
            info!(
                "submit Hero action: create child for match {} in tournament {tournament}",
                match_id.hash()
            );
            sender::seal_inner_match(
                provider,
                tournament,
                match_id,
                left_leaf,
                right_leaf,
                &agree_state_proof,
            )
        }
        PreparedArenaAction::ProveLeaf {
            tournament,
            match_id,
            left_node,
            right_node,
            proof,
        } => {
            info!(
                "submit Hero action: prove leaf match {} in tournament {tournament}",
                match_id.hash()
            );
            sender::win_leaf_match(provider, tournament, match_id, left_node, right_node, proof)
        }
        PreparedArenaAction::PropagateChild {
            parent_tournament,
            child_tournament,
            left_node,
            right_node,
        } => {
            info!(
                "submit Hero action: propagate child {child_tournament} into tournament {parent_tournament}"
            );
            sender::win_inner_match(
                provider,
                parent_tournament,
                child_tournament,
                left_node,
                right_node,
            )
        }
    })
}

#[cfg(test)]
mod tests {
    use alloy::{
        primitives::{TxKind, U256},
        sol_types::SolCall,
    };
    use cartesi_prt_contracts::tournament::Tournament;

    use super::*;
    use crate::{chain::recording::recording_provider, merkle::MerkleProof, tournament::MatchID};

    fn address(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn digest(byte: u8) -> Digest {
        Digest::new([byte; 32])
    }

    fn match_id() -> MatchID {
        MatchID {
            commitment_one: digest(1),
            commitment_two: digest(2),
        }
    }

    fn head() -> ChainHead {
        ChainHead {
            number: 9,
            hash: alloy::primitives::B256::repeat_byte(9),
        }
    }

    #[tokio::test]
    async fn each_prepared_variant_yields_its_verb_and_only_the_join_reads_the_bond() {
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        asserter.push_success(&alloy::primitives::Bytes::from(
            Tournament::bondValueCall::abi_encode_returns(&U256::from(7)),
        ));
        let tournament = address(1);
        let child = address(2);
        let proof = || MerkleProof::leaf(digest(3), U256::ZERO);

        let actions = [
            (
                PreparedArenaAction::Join {
                    tournament,
                    proof_last: proof(),
                    left_child: digest(4),
                    right_child: digest(5),
                },
                "joinTournament",
                Tournament::joinTournamentCall::SELECTOR,
            ),
            (
                PreparedArenaAction::ClaimTimeout {
                    tournament,
                    match_id: match_id(),
                    left_node: digest(4),
                    right_node: digest(5),
                },
                "winMatchByTimeout",
                Tournament::winMatchByTimeoutCall::SELECTOR,
            ),
            (
                PreparedArenaAction::Advance {
                    tournament,
                    match_id: match_id(),
                    left_node: digest(4),
                    right_node: digest(5),
                    new_left_node: digest(6),
                    new_right_node: digest(7),
                },
                "advanceMatch",
                Tournament::advanceMatchCall::SELECTOR,
            ),
            (
                PreparedArenaAction::SealLeaf {
                    tournament,
                    match_id: match_id(),
                    left_leaf: digest(4),
                    right_leaf: digest(5),
                    agree_state_proof: proof(),
                },
                "sealLeafMatch",
                Tournament::sealLeafMatchCall::SELECTOR,
            ),
            (
                PreparedArenaAction::CreateChild {
                    tournament,
                    match_id: match_id(),
                    left_leaf: digest(4),
                    right_leaf: digest(5),
                    agree_state_proof: proof(),
                },
                "sealInnerMatchAndCreateInnerTournament",
                Tournament::sealInnerMatchAndCreateInnerTournamentCall::SELECTOR,
            ),
            (
                PreparedArenaAction::ProveLeaf {
                    tournament,
                    match_id: match_id(),
                    left_node: digest(4),
                    right_node: digest(5),
                    proof: vec![1, 2, 3],
                },
                "winLeafMatch",
                Tournament::winLeafMatchCall::SELECTOR,
            ),
            (
                PreparedArenaAction::PropagateChild {
                    parent_tournament: tournament,
                    child_tournament: child,
                    left_node: digest(4),
                    right_node: digest(5),
                },
                "winInnerTournament",
                Tournament::winInnerTournamentCall::SELECTOR,
            ),
        ];

        for (action, verb, selector) in actions {
            let is_join = matches!(action, PreparedArenaAction::Join { .. });
            let (label, request) = request_prepared(&chain, action, head()).await.unwrap();
            assert_eq!(label, verb);
            assert_eq!(&request.input.input().unwrap()[..4], selector.as_slice());
            assert_eq!(request.to, Some(TxKind::Call(tournament)));
            assert_eq!(request.value, is_join.then(|| U256::from(7)));
        }
        assert!(asserter.read_q().is_empty());

        // The one read is the join's bond, pinned to the action head.
        let requests = requests.lock().unwrap();
        let calls: Vec<_> = requests
            .iter()
            .filter(|request| request["method"] == "eth_call")
            .collect();
        assert_eq!(calls.len(), 1);
        assert_eq!(
            calls[0]["params"][1],
            serde_json::json!(format!("{:#x}", head().hash))
        );
    }
}
