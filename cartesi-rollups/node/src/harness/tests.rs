// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Lifecycle scenarios with the honest node alone (every root tournament
//! has one claimer, so it closes after its allowance and settles), then
//! disputes against adversaries.

use super::*;
use crate::merkle::Digest;
use alloy::{
    primitives::{FixedBytes, U256},
    sol_types::SolCall,
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus::{
    acceptStagedTournamentResultCall, stageTournamentResultCall, submitSentryClaimCall,
};
use cartesi_prt_contracts::tournament::Tournament::{
    MatchCreated, advanceMatchCall, eliminateInnerTournamentCall, eliminateMatchByTimeoutCall,
    joinTournamentCall, sealInnerMatchAndCreateInnerTournamentCall, tryRecoveringBondCall,
    winInnerTournamentCall, winLeafMatchCall, winMatchByTimeoutCall,
};

/// The largest payload whose EvmAdvance-encoded input fits the InputBox's
/// 2^16-byte limit: a 4-byte selector and nine head words, then the payload
/// padded to a word. One byte more pads past the limit.
const MAX_PAYLOAD: usize = ((1 << 16) - 4 - 9 * 32) / 32 * 32;

/// A generous bound on the rounds any one lifecycle phase takes; a phase
/// that needs more is stuck, and run_until reports where.
const ROUNDS: usize = 64;

const JOIN: FixedBytes<4> = FixedBytes(joinTournamentCall::SELECTOR);
const CLAIM: FixedBytes<4> = FixedBytes(submitSentryClaimCall::SELECTOR);
const STAGE: FixedBytes<4> = FixedBytes(stageTournamentResultCall::SELECTOR);
const ACCEPT: FixedBytes<4> = FixedBytes(acceptStagedTournamentResultCall::SELECTOR);
const WIN_TIMEOUT: FixedBytes<4> = FixedBytes(winMatchByTimeoutCall::SELECTOR);
const ADVANCE: FixedBytes<4> = FixedBytes(advanceMatchCall::SELECTOR);
const WIN_LEAF: FixedBytes<4> = FixedBytes(winLeafMatchCall::SELECTOR);
const WIN_INNER: FixedBytes<4> = FixedBytes(winInnerTournamentCall::SELECTOR);
const ELIMINATE_MATCH: FixedBytes<4> = FixedBytes(eliminateMatchByTimeoutCall::SELECTOR);
const ELIMINATE_INNER: FixedBytes<4> = FixedBytes(eliminateInnerTournamentCall::SELECTOR);

// ITournament's MatchDeletionReason, WinnerCommitment and
// MatchTimeoutOutcome, as event and view bytes.
const TIMEOUT: u8 = 1;
const CHILD_TOURNAMENT: u8 = 2;
const NO_WINNER: u8 = 0;
const TWO_WON: u8 = 2;
const OUTCOME_NONE: u8 = 0;
const TWO_WINS: u8 = 2;
const ELIMINATE_BOTH: u8 = 3;

/// A bound on the rounds of a whole dispute: about 92 bisections, the
/// joins and seals between levels, and the root's allowance.
const DISPUTE_ROUNDS: usize = 1000;

/// Whether the node completed `epoch`: settled, with its bonds finalized.
fn completed(storage: &mut Storage, epoch: u64) -> Result<bool> {
    Ok(match storage.unfinished_epoch()? {
        Some(unfinished) => unfinished.epoch_number > epoch,
        None => storage.epoch_count()? > epoch,
    })
}

/// Turns until the node's root join mines, then mines to the root's close.
async fn join_and_close(node: &mut Node, world: &mut World) -> Result<()> {
    let joins = world.honest_calls(JOIN).len();
    node.run_until(world, ROUNDS, |world, _| {
        Ok(world.honest_calls(JOIN).len() > joins)
    })
    .await?;
    let close = world.root_closes_at().await?;
    world.mine_to(close).await
}

async fn settle(node: &mut Node, world: &mut World, epoch: u64) -> Result<()> {
    join_and_close(node, world).await?;
    node.run_until(world, ROUNDS, |_, storage| completed(storage, epoch))
        .await
}

/// Two consecutive epochs settle: epoch 0, sealed empty at deployment, and
/// epoch 1 with a maximum-size input, which the reader ingests and the
/// runner executes before the node joins with its root.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn consecutive_epochs_settle_including_a_maximum_size_input() -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    assert!(world.accepts_input(vec![0xab; MAX_PAYLOAD]).await);
    assert!(
        !world.accepts_input(vec![0xab; MAX_PAYLOAD + 1]).await,
        "the InputBox must refuse one byte past the maximum"
    );
    world.add_input(vec![0xab; MAX_PAYLOAD]).await?;
    let mut node = world.honest_node().await?;

    settle(&mut node, &mut world, 0).await?;
    settle(&mut node, &mut world, 1).await?;

    let sealed = world.sealed_epochs().await?;
    assert_eq!(sealed.len(), 3, "the settlements sealed epochs 1 and 2");
    assert_eq!(
        sealed[1].inputIndexUpperBound - sealed[1].inputIndexLowerBound,
        U256::ONE,
        "epoch 1 holds the input"
    );
    assert_ne!(
        sealed[2].initialMachineStateHash, sealed[1].initialMachineStateHash,
        "epoch 1 settled the state after the input"
    );
    assert_eq!(world.honest_calls(ACCEPT).len(), 2);

    // The bytes the node ingested and executed are the InputBox's input,
    // the hash DaveConsensus checks when the step asks for its root.
    let stored = Storage::new(node.state_dir.path())?.inputs(1)?;
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].len(), 4 + 9 * 32 + MAX_PAYLOAD);
    let input_hash = IInputBox::new(world.book.input_box, world.chain.provider().clone())
        .getInputHash(world.book.app, U256::ZERO)
        .call()
        .await?;
    assert_eq!(alloy::primitives::keccak256(&stored[0]), input_hash);
    Ok(())
}

/// A restart around the acceptance of a staged result (kill_settle): the
/// acceptance is lost with the process, or it mined just before. Either
/// way the restarted node settles the epoch exactly once.
async fn restart_around_acceptance(accepted_before_restart: bool) -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    join_and_close(&mut node, &mut world).await?;

    // Claim, then stage: the next tick plans the acceptance.
    node.run_until(&mut world, ROUNDS, |world, _| {
        Ok(!world.honest_calls(CLAIM).is_empty() && !world.honest_calls(STAGE).is_empty())
    })
    .await?;
    node.tick(&world).await?;
    if accepted_before_restart {
        world.mine(1).await?;
        assert_eq!(world.honest_calls(ACCEPT).len(), 1);
    } else {
        world.drop_pending().await?;
        assert!(world.honest_calls(ACCEPT).is_empty());
    }

    let mut node = node.restart(&world)?;
    node.run_until(&mut world, ROUNDS, |_, storage| completed(storage, 0))
        .await?;
    assert_eq!(world.honest_calls(ACCEPT).len(), 1, "one acceptance");
    assert_eq!(world.sealed_epochs().await?.len(), 2, "epoch 1 sealed once");
    Ok(())
}

#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn restart_after_a_lost_acceptance_settles_once() -> Result<()> {
    restart_around_acceptance(false).await
}

#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn restart_after_a_mined_acceptance_settles_once() -> Result<()> {
    restart_around_acceptance(true).await
}

/// With a second sentry that never claims, sentries do not agree, so the
/// node accepts only once the claim staging period has elapsed since the
/// result was staged.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn acceptance_waits_out_the_staging_period_without_unanimity() -> Result<()> {
    const PERIOD: u64 = 30;
    let mut world = World::spawn(&[HONEST, 8], PERIOD).await?;
    let mut node = world.honest_node().await?;
    join_and_close(&mut node, &mut world).await?;
    node.run_until(&mut world, ROUNDS + PERIOD as usize, |_, storage| {
        completed(storage, 0)
    })
    .await?;

    let staged = world.honest_calls(STAGE);
    let accepted = world.honest_calls(ACCEPT);
    assert_eq!((staged.len(), accepted.len()), (1, 1));
    assert!(
        accepted[0].block >= staged[0].block + PERIOD,
        "accepted at block {} with the result staged at block {}",
        accepted[0].block,
        staged[0].block
    );
    Ok(())
}

// Disputes. Epoch 0 is empty, so every transition past the deployment is
// idle and every build only captures idle cycles; the adversaries diverge at
// the first transition of the second root leaf.

fn idle_tail() -> Tail {
    tail(1, 0xee)
}

/// A divergence at the first transition of root leaf `leaf`, an idle
/// one in epoch 0; distinct `fill`s give distinct commitments.
fn tail(leaf: u64, fill: u8) -> Tail {
    Tail {
        from: U256::from(leaf) << 44,
        value: Digest::from_digest(&[fill; 32]).unwrap(),
    }
}

/// Requires exactly one MatchDeleted for `created`, with this reason and
/// winner.
async fn assert_deleted(
    world: &World,
    tournament: Address,
    created: &MatchCreated,
    reason: u8,
    winner: u8,
) -> Result<()> {
    let deletions: Vec<_> = world
        .matches_deleted(tournament)
        .await?
        .into_iter()
        .filter(|deleted| deleted.matchIdHash == created.matchIdHash)
        .collect();
    assert_eq!(deletions.len(), 1, "one deletion of the match");
    let deleted = &deletions[0];
    assert_eq!((deleted.one, deleted.two), (created.one, created.two));
    assert_eq!((deleted.reason, deleted.winnerCommitment), (reason, winner));
    Ok(())
}

/// A joiner that goes silent (bad_commitment) loses its root match by
/// timeout to the node, which then settles the epoch.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn a_silent_joiner_loses_by_timeout() -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    let mut adversary =
        world.adversary(&node, 1, idle_tail(), Policy::StopAfter("joinTournament"))?;

    node.run_with(
        &mut world,
        &mut [&mut adversary],
        DISPUTE_ROUNDS,
        |_, storage| completed(storage, 0),
    )
    .await?;
    assert_eq!(world.honest_calls(WIN_TIMEOUT).len(), 1);
    assert!(world.honest_calls(WIN_LEAF).is_empty());
    assert_eq!(world.sealed_epochs().await?.len(), 2);
    Ok(())
}

/// A rational adversary disputes down to the leaf, where only the node
/// can prove the divergent transition, a closing slot (simple): the node
/// wins the leaf match by STEP, each inner tournament in turn, and
/// settles. (The node moves first in a round, so it proves before the
/// adversary can try; the overlay's own tests show the adversary cannot.)
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn the_node_wins_by_proving_the_divergent_transition() -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    // The last transition of the first root leaf: a closing slot, so the
    // node's proof carries a ustep and the uarch reset.
    let closing_slot = Tail {
        from: (U256::ONE << 44) - U256::ONE,
        ..idle_tail()
    };
    let mut adversary = world.adversary(&node, 1, closing_slot, Policy::Rational)?;

    node.run_with(
        &mut world,
        &mut [&mut adversary],
        DISPUTE_ROUNDS,
        |_, storage| completed(storage, 0),
    )
    .await?;
    assert_eq!(world.honest_calls(WIN_LEAF).len(), 1);
    assert_eq!(
        world.honest_calls(WIN_INNER).len(),
        world.levels() - 1,
        "the node won every inner tournament on its way back to the root"
    );
    assert_eq!(world.sealed_epochs().await?.len(), 2);
    Ok(())
}

/// Two adversaries join first, pair with each other and abandon their
/// match (gc_match): the node joins unpaired, deletes their match by
/// timeout once it is eliminable, and wins the root alone.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn the_node_collects_an_abandoned_match() -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    let mut one = world.adversary(&node, 1, tail(1, 0xa1), Policy::StopAfter("joinTournament"))?;
    let mut two = world.adversary(&node, 2, tail(2, 0xb2), Policy::StopAfter("joinTournament"))?;
    one.turn(&mut world).await?;
    two.turn(&mut world).await?;
    let root = world.sealed_epochs().await?[0].tournament;
    let paired = world.matches_created(root).await?;
    assert_eq!(paired.len(), 1, "the adversaries paired with each other");

    node.run_with(
        &mut world,
        &mut [&mut one, &mut two],
        DISPUTE_ROUNDS,
        |_, storage| completed(storage, 0),
    )
    .await?;
    assert_deleted(&world, root, &paired[0], TIMEOUT, NO_WINNER).await?;
    assert_eq!(world.honest_calls(ELIMINATE_MATCH).len(), 1);
    assert_eq!(world.sealed_epochs().await?.len(), 2);
    Ok(())
}

/// Two adversaries pair, take their root match into a child tournament,
/// join it, and abandon it (gc_tournament): the node deletes the child
/// match by timeout, then the parent match by its child, and wins the
/// root alone.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn the_node_collects_an_abandoned_child_tournament() -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    let mut one = world.adversary(&node, 1, tail(1, 0xa1), Policy::Rational)?;
    let mut two = world.adversary(&node, 2, tail(2, 0xb2), Policy::Rational)?;
    one.turn(&mut world).await?;
    two.turn(&mut world).await?;
    let root = world.sealed_epochs().await?[0].tournament;
    let paired = world.matches_created(root).await?;
    assert_eq!(paired.len(), 1, "the adversaries paired with each other");

    // Each adversary's second join is into the child.
    let join = FixedBytes(joinTournamentCall::SELECTOR);
    node.run_with(
        &mut world,
        &mut [&mut one, &mut two],
        DISPUTE_ROUNDS,
        |world, _| Ok(world.calls(1, join).len() == 2 && world.calls(2, join).len() == 2),
    )
    .await?;
    one.stop();
    two.stop();
    let children = world.inner_tournaments(root).await?;
    assert_eq!(children.len(), 1);
    let child = children[0].childTournament;
    let lazy_child = world.matches_created(child).await?;
    assert_eq!(lazy_child.len(), 1, "the adversaries paired in the child");

    node.run_until(&mut world, DISPUTE_ROUNDS, |_, storage| {
        completed(storage, 0)
    })
    .await?;
    assert_deleted(&world, child, &lazy_child[0], TIMEOUT, NO_WINNER).await?;
    assert_deleted(&world, root, &paired[0], CHILD_TOURNAMENT, NO_WINNER).await?;
    assert_eq!(world.honest_calls(ELIMINATE_MATCH).len(), 1);
    assert_eq!(world.honest_calls(ELIMINATE_INNER).len(), 1);
    assert_eq!(world.sealed_epochs().await?.len(), 2);
    Ok(())
}

/// The node is down for `blocks` blocks while the adversaries play on.
async fn downtime(
    world: &mut World,
    adversaries: &mut [&mut Adversary],
    blocks: usize,
) -> Result<()> {
    for _ in 0..blocks {
        for adversary in adversaries.iter_mut() {
            adversary.turn(world).await?;
        }
        world.mine(1).await?;
    }
    Ok(())
}

/// A restart in the middle of `simple`'s dispute (kill_join,
/// kill_mid_match): once `ready` holds, the node plans its next action
/// and dies; the action is lost with it, or mined just before. The node
/// stays down for ten blocks while the adversary plays on, restarts over
/// the same state, and still wins and settles; a repeated action would
/// revert and fail the run.
async fn restart_mid_dispute(
    ready: impl FnMut(&World, &mut Storage) -> Result<bool>,
    action: FixedBytes<4>,
    mined_before_restart: bool,
) -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    let mut adversary = world.adversary(&node, 1, idle_tail(), Policy::Rational)?;
    node.run_with(&mut world, &mut [&mut adversary], DISPUTE_ROUNDS, ready)
        .await?;

    let before = world.honest_calls(action).len();
    node.tick(&world).await?;
    if mined_before_restart {
        world.mine(1).await?;
        assert_eq!(
            world.honest_calls(action).len(),
            before + 1,
            "the action mined"
        );
    } else {
        world.drop_pending().await?;
    }
    let mut node = node.restart(&world)?;
    downtime(&mut world, &mut [&mut adversary], 10).await?;

    node.run_with(
        &mut world,
        &mut [&mut adversary],
        DISPUTE_ROUNDS,
        |_, storage| completed(storage, 0),
    )
    .await?;
    assert_eq!(world.honest_calls(WIN_LEAF).len(), 1);
    assert_eq!(world.sealed_epochs().await?.len(), 2);
    Ok(())
}

#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn restart_after_a_lost_join_wins_the_dispute() -> Result<()> {
    restart_mid_dispute(|_, _| Ok(true), JOIN, false).await
}

#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn restart_after_a_mined_join_wins_the_dispute() -> Result<()> {
    restart_mid_dispute(|_, _| Ok(true), JOIN, true).await
}

/// After the node's first advance, its next tick advances again.
fn advanced(world: &World, _: &mut Storage) -> Result<bool> {
    Ok(!world.honest_calls(ADVANCE).is_empty())
}

#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn restart_after_a_lost_advance_wins_the_dispute() -> Result<()> {
    restart_mid_dispute(advanced, ADVANCE, false).await
}

#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn restart_after_a_mined_advance_wins_the_dispute() -> Result<()> {
    restart_mid_dispute(advanced, ADVANCE, true).await
}

/// Three sybils (multi_sybil): join order pairs the node with the first
/// while the second pairs with the third, who joins and goes silent, so the
/// root holds two concurrent matches. The node beats the first by STEP; the
/// second outlasts the silent sybil (deleted by timeout without winning),
/// meets the node and loses by STEP too. The node restarts once its bond
/// recovery has begun, before the epoch completes, and recovers exactly one
/// bond on the root, paid to itself, before it joins the next root; the
/// root's balance drains.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn three_sybils_lose_and_the_node_recovers_its_bond_first() -> Result<()> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    let mut one = world.adversary(&node, 1, tail(1, 0xa1), Policy::Rational)?;
    let mut two = world.adversary(&node, 2, tail(2, 0xb2), Policy::Rational)?;
    let mut silent =
        world.adversary(&node, 3, tail(3, 0xc3), Policy::StopAfter("joinTournament"))?;
    one.turn(&mut world).await?;
    node.turn(&mut world).await?;
    two.turn(&mut world).await?;
    silent.turn(&mut world).await?;
    let root = world.sealed_epochs().await?[0].tournament;
    assert_eq!(
        world.matches_created(root).await?.len(),
        2,
        "two concurrent matches"
    );

    let recover = FixedBytes(tryRecoveringBondCall::SELECTOR);
    node.run_with(
        &mut world,
        &mut [&mut one, &mut two, &mut silent],
        DISPUTE_ROUNDS,
        |world, _| Ok(!world.honest_calls(recover).is_empty()),
    )
    .await?;
    assert!(
        !completed(&mut Storage::new(node.state_dir.path())?, 0)?,
        "the restart lands before the epoch completes"
    );
    let mut node = node.restart(&world)?;
    node.run_with(
        &mut world,
        &mut [&mut one, &mut two, &mut silent],
        DISPUTE_ROUNDS,
        |_, storage| completed(storage, 0),
    )
    .await?;
    // Epoch 1 is empty and undisputed: the node's next join is its root.
    let joins = world.honest_calls(JOIN).len();
    node.run_until(&mut world, ROUNDS, |world, _| {
        Ok(world.honest_calls(JOIN).len() > joins)
    })
    .await?;
    let next_root = world.sealed_epochs().await?[1].tournament;
    assert_eq!(
        world.honest_calls(WIN_LEAF).len(),
        2,
        "two leaf wins by STEP"
    );

    let joined = world.commitments_joined(root).await?;
    assert_eq!(joined.len(), 4, "the node and three sybils joined the root");
    let commitment_of = |key: usize| {
        joined
            .iter()
            .find(|(join, _)| join.submitter == world.address(key))
            .map(|(join, _)| join.commitment)
            .unwrap()
    };
    let (silent_commitment, honest_commitment) = (commitment_of(3), commitment_of(HONEST));
    let silent_timeouts: Vec<_> = world
        .matches_deleted(root)
        .await?
        .into_iter()
        .filter(|deleted| {
            let won = (deleted.one == silent_commitment && deleted.winnerCommitment == 1)
                || (deleted.two == silent_commitment && deleted.winnerCommitment == 2);
            (deleted.one == silent_commitment || deleted.two == silent_commitment)
                && deleted.reason == TIMEOUT
                && !won
        })
        .collect();
    assert_eq!(silent_timeouts.len(), 1, "the silent sybil timed out once");

    let recoveries = world.bonds_recovered(root).await?;
    assert_eq!(recoveries.len(), 1, "exactly one bond recovery");
    let (recovery, recovered_at) = &recoveries[0];
    assert_eq!(recovery.commitment, honest_commitment);
    assert_eq!(recovery.claimer, world.address(HONEST));
    let next_joins = world.commitments_joined(next_root).await?;
    assert_eq!(next_joins.len(), 1, "the node joined the next root once");
    assert!(
        *recovered_at < next_joins[0].1,
        "recovery precedes the next join"
    );
    assert_eq!(
        world.balance(root).await?,
        U256::ZERO,
        "the root's balance drained"
    );
    Ok(())
}

/// A sealed leaf match whose clocks end at different blocks, the honest
/// node's the longer one, with the node offline from the seal on.
struct SealedLeaf {
    world: World,
    node: Node,
    leaf: Address,
    created: MatchCreated,
    seal: u64,
    short: u64,
    long: u64,
}

/// Plays simple's dispute down to the leaf seal. The adversary joins each
/// child before the node (the node sits out the rounds in between), so it
/// is commitment one at every odd-height level below the root and the
/// leaf's final responder. It holds its seal until three blocks before its
/// own clock expires: the seal charges its overdue time, so its reserve
/// after the seal falls well below the node's, which was paused.
async fn sealed_leaf() -> Result<SealedLeaf> {
    let mut world = World::spawn(&[HONEST], 1000).await?;
    for level in &world.geometry_heights()[1..] {
        assert_eq!(
            level % 2,
            1,
            "the choreography needs odd heights below the root"
        );
    }
    let mut node = world.honest_node().await?;
    node.roll(&mut world, 0).await?;
    let mut adversary = world.adversary(&node, 1, idle_tail(), Policy::Hold("sealLeafMatch"))?;

    let seal_inner = FixedBytes(sealInnerMatchAndCreateInnerTournamentCall::SELECTOR);
    for _ in 0..DISPUTE_ROUNDS {
        if adversary.holding() {
            break;
        }
        let seals = world
            .mined
            .iter()
            .filter(|mined| mined.selector == Some(seal_inner))
            .count();
        if world.calls(1, JOIN).len() > seals {
            node.turn(&mut world).await?;
        } else {
            world.mine(1).await?;
        }
        adversary.turn(&mut world).await?;
    }
    assert!(
        adversary.holding(),
        "the adversary never reached its leaf seal"
    );

    let root = world.sealed_epochs().await?[0].tournament;
    let leaf = world.deepest(root).await?;
    let matches = world.matches_created(leaf).await?;
    assert_eq!(matches.len(), 1);
    let created = matches[0].clone();
    let honest_joins: Vec<_> = world
        .commitments_joined(leaf)
        .await?
        .into_iter()
        .filter(|(join, _)| join.submitter == world.address(HONEST))
        .collect();
    assert_eq!(honest_joins.len(), 1);
    assert_eq!(
        honest_joins[0].0.commitment, created.two,
        "the node is commitment two"
    );
    let one = world.standing(leaf, created.one).await?;
    let two = world.standing(leaf, created.two).await?;
    assert!(
        one.clockRunning && !two.clockRunning,
        "one responds, two waits"
    );

    world.mine_to(one.clockDeadline - 3 - 1).await?;
    adversary.release(&mut world).await?;
    let seal = world.latest().await?;
    let (short, long) = (
        world.standing(leaf, created.one).await?.clockDeadline,
        world.standing(leaf, created.two).await?.clockDeadline,
    );
    assert!(
        short + 80 <= long,
        "deadlines {short} and {long} are too close"
    );
    Ok(SealedLeaf {
        world,
        node,
        leaf,
        created,
        seal,
        short,
        long,
    })
}

/// The longer clock wins (sealed_leaf_timeout_winner): the outcome turns
/// from none to two-wins exactly at the short deadline and stays so past
/// the midpoint where a retired classifier used to flip; the node,
/// restarted there, claims the timeout in the very next block, before the
/// long deadline. The match is deleted by timeout, not by a proof.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn the_longer_clock_wins_a_sealed_leaf_by_timeout() -> Result<()> {
    let SealedLeaf {
        mut world,
        node,
        leaf,
        created,
        seal,
        short,
        long,
    } = sealed_leaf().await?;
    world.mine_to(short).await?;
    assert_eq!(
        world.timeout_outcome_at(leaf, &created, short - 1).await?,
        OUTCOME_NONE
    );
    assert_eq!(
        world.timeout_outcome_at(leaf, &created, short).await?,
        TWO_WINS
    );

    let midpoint = seal + (short - seal + long - seal).div_ceil(2);
    let observation = midpoint + 1;
    assert!(observation + 1 < long);
    world.mine_to(observation).await?;
    assert_eq!(
        world
            .timeout_outcome_at(leaf, &created, observation)
            .await?,
        TWO_WINS
    );

    // Back online as a fresh process, as the Lua scenario respawned it.
    let mut node = node.restart(&world)?;
    node.turn(&mut world).await?;
    assert_deleted(&world, leaf, &created, TIMEOUT, TWO_WON).await?;
    let claims = world.honest_calls(WIN_TIMEOUT);
    assert_eq!(claims.len(), 1);
    assert_eq!(
        claims[0].block,
        observation + 1,
        "claimed in the first block after observation"
    );
    Ok(())
}

/// Both clocks expire (sealed_leaf_timeout_both): the outcome turns from
/// two-wins to eliminate-both exactly at the long deadline, and the node,
/// restarted there, deletes the match in the very next block with no
/// winner.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn both_clocks_expire_on_a_sealed_leaf() -> Result<()> {
    let SealedLeaf {
        mut world,
        node,
        leaf,
        created,
        long,
        ..
    } = sealed_leaf().await?;
    world.mine_to(long).await?;
    assert_eq!(
        world.timeout_outcome_at(leaf, &created, long - 1).await?,
        TWO_WINS
    );
    assert_eq!(
        world.timeout_outcome_at(leaf, &created, long).await?,
        ELIMINATE_BOTH
    );

    // Back online as a fresh process, as the Lua scenario respawned it.
    let mut node = node.restart(&world)?;
    node.turn(&mut world).await?;
    assert_deleted(&world, leaf, &created, TIMEOUT, NO_WINNER).await?;
    let eliminations = world.honest_calls(ELIMINATE_MATCH);
    assert_eq!(eliminations.len(), 1);
    assert_eq!(
        eliminations[0].block,
        long + 1,
        "eliminated right after the exact boundary"
    );
    Ok(())
}
