// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Lifecycle scenarios with the honest node alone: every root tournament
//! has one claimer, so it closes after its allowance and settles.

use super::*;
use alloy::{
    primitives::{FixedBytes, U256},
    sol_types::SolCall,
};
use cartesi_dave_contracts::dave_consensus::DaveConsensus::{
    acceptStagedTournamentResultCall, stageTournamentResultCall, submitSentryClaimCall,
};
use cartesi_prt_contracts::tournament::Tournament::joinTournamentCall;

/// The largest payload whose EvmAdvance-encoded input fits the InputBox's
/// 2^16-byte limit (what the big_input e2e scenario sent).
const MAX_PAYLOAD: usize = (1 << 16) - 32 * 13;

/// A generous bound on the rounds any one lifecycle phase takes; a phase
/// that needs more is stuck, and run_until reports where.
const ROUNDS: usize = 64;

const JOIN: FixedBytes<4> = FixedBytes(joinTournamentCall::SELECTOR);
const CLAIM: FixedBytes<4> = FixedBytes(submitSentryClaimCall::SELECTOR);
const STAGE: FixedBytes<4> = FixedBytes(stageTournamentResultCall::SELECTOR);
const ACCEPT: FixedBytes<4> = FixedBytes(acceptStagedTournamentResultCall::SELECTOR);

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
