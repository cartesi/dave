// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! A node seeded from the application's last settled state: the seeding
//! gate through `NodeConfig::setup_with`, as the binary starts, then the
//! seeded node's workers on the deterministic chain.

use super::*;
use crate::{
    args::{NodeConfig, PRTArgs},
    merkle::Digest,
};
use alloy::{primitives::FixedBytes, sol_types::SolCall};
use cartesi_dave_contracts::dave_consensus::DaveConsensus::acceptStagedTournamentResultCall;
use cartesi_prt_contracts::tournament::Tournament::joinTournamentCall;
use clap::Parser;
use std::path::Path;

/// A generous bound on the rounds any one lifecycle phase takes.
const ROUNDS: usize = 64;

const JOIN: FixedBytes<4> = FixedBytes(joinTournamentCall::SELECTOR);
const ACCEPT: FixedBytes<4> = FixedBytes(acceptStagedTournamentResultCall::SELECTOR);

/// Whether the node completed `epoch`: settled, with its bonds finalized.
fn completed(storage: &mut Storage, epoch: u64) -> Result<bool> {
    Ok(match storage.unfinished_epoch()? {
        Some(unfinished) => unfinished.epoch_number > epoch,
        None => storage.epoch_count()? > epoch,
    })
}

/// Turns until the node's next root join mines.
async fn join(node: &mut Node, world: &mut World) -> Result<()> {
    let key = node.key;
    let joins = world.calls(key, JOIN).len();
    node.run_until(world, ROUNDS, |world, _| {
        Ok(world.calls(key, JOIN).len() > joins)
    })
    .await
}

/// Joins the current root, mines to its close, and turns until the node
/// completed `epoch`.
async fn settle(node: &mut Node, world: &mut World, epoch: u64) -> Result<()> {
    join(node, world).await?;
    let close = world.root_closes_at().await?;
    world.mine_to(close).await?;
    node.run_until(world, ROUNDS, |_, storage| completed(storage, epoch))
        .await
}

/// The binary's arguments for anvil key `key` over `data_dir`.
fn args(world: &World, key: usize, template: &Path, data_dir: &Path) -> PRTArgs {
    PRTArgs::try_parse_from([
        "cartesi-sling-node".to_owned(),
        "--app-address".to_owned(),
        world.book.app.to_string(),
        "--template-path".to_owned(),
        template.to_str().unwrap().to_owned(),
        "--blockchain-http-endpoint".to_owned(),
        world.anvil.endpoint(),
        "--blockchain-id".to_owned(),
        world.anvil.chain_id().to_string(),
        "--data-dir".to_owned(),
        data_dir.to_str().unwrap().to_owned(),
        "pk".to_owned(),
        "--auth-private-key".to_owned(),
        alloy::hex::encode(world.anvil.keys()[key].to_bytes()),
    ])
    .unwrap()
}

/// Node A (the honest key) settles epoch 0 and joins root 1, then stops;
/// node C (another key, from genesis) settles epoch 1 on A's commitment,
/// whose bond is A's signer's. Node B, on A's key, is seeded from C's
/// snapshot of epoch 2's start: it recovers A's root-1 bond without
/// executing epochs 0 and 1, refuses its own unsettled final state as a
/// seed, and settles epoch 2. A restart reads no image.
#[tokio::test]
#[ignore = "needs the devnet bundle and the echo image; run `just test-node-harness`"]
async fn a_node_seeded_from_the_settled_state_recovers_earlier_bonds_and_defends_its_epoch()
-> Result<()> {
    const C: usize = 1;
    let mut world = World::spawn(&[], 10).await?;
    world.add_input(b"one".to_vec()).await?;

    let mut a = world.honest_node().await?;
    settle(&mut a, &mut world, 0).await?;
    world.add_input(b"two".to_vec()).await?;
    join(&mut a, &mut world).await?;
    drop(a);
    world.drop_pending().await?;
    let close = world.root_closes_at().await?;
    world.mine_to(close).await?;

    let mut c = world.node(C).await?;
    c.run_until(&mut world, ROUNDS, |world, _| {
        Ok(world.calls(C, ACCEPT).len() == 1)
    })
    .await?;
    world.mine(2).await?;
    let from_c = world.address(C);
    assert!(
        world
            .mined
            .iter()
            .filter(|mined| mined.from == from_c)
            .all(|mined| mined.success),
        "node C's transactions reverted:\n{}",
        world.trace()
    );

    let sealed = world.sealed_epochs().await?;
    assert_eq!(sealed.len(), 3, "epochs 1 and 2 sealed");
    let start = sealed[2].initialMachineStateHash.0;
    assert_ne!(
        start, world.book.initial_hash,
        "epoch 1's input moved the state"
    );
    let mut c_storage = Storage::new(c.state_dir.path())?;
    assert_eq!(c_storage.snapshot_hash(2, 0)?, Some(start));
    let root_1 = sealed[1].tournament;
    assert!(world.bonds_recovered(root_1).await?.is_empty());

    // B seeds from C's store, as an operator copies another node's image.
    let image = c_storage.snapshot_dir(2, 0)?.context("C's epoch-2 start")?;
    let b_dir = tempfile::tempdir()?;
    let config = NodeConfig::setup_with(args(&world, HONEST, &image, b_dir.path())).await?;
    let mut b_storage = Storage::new(b_dir.path())?;
    assert_eq!(b_storage.snapshot_hash(2, 0)?, Some(start));
    assert!(b_storage.snapshot_hash(0, 0)?.is_none());
    assert_eq!(
        b_storage.sling_config()?.template_hash,
        Digest::new(world.book.initial_hash),
        "the pin keeps the deployment's initial hash"
    );

    let joins = world.honest_calls(JOIN).len();
    let mut b = Node::start(&world, b_dir, HONEST)?;
    b.run_until(&mut world, ROUNDS, |_, storage| completed(storage, 1))
        .await?;
    let recovered = world.bonds_recovered(root_1).await?;
    assert_eq!(recovered.len(), 1, "A's root-1 bond, recovered by B");
    assert_eq!(recovered[0].0.claimer, world.address(HONEST));
    assert_eq!(
        world.honest_calls(JOIN).len(),
        joins,
        "no join below the seed"
    );

    // A computed but unsettled state seeds nothing, and creates nothing.
    b.roll(&mut world, 2).await?;
    let computed = b_storage
        .settlement_info(2)?
        .context("B rolled epoch 2")?
        .final_state;
    let unsettled = b_storage.snapshot_dir(3, 0)?.context("B's epoch-3 start")?;
    let scratch = tempfile::tempdir()?;
    let refused = scratch.path().join("refused");
    let error = NodeConfig::setup_with(args(&world, HONEST, &unsettled, &refused))
        .await
        .map(|_| ())
        .unwrap_err();
    assert_eq!(crate::fatal::exit_code(&error), 30, "{error:#}");
    assert!(
        format!("{error:#}").contains(&alloy::hex::encode_prefixed(start)),
        "the refusal names the state to take: {error:#}"
    );
    assert!(!refused.exists(), "a refused start must not write");

    settle(&mut b, &mut world, 2).await?;
    assert_eq!(
        world.honest_calls(JOIN).len(),
        joins + 1,
        "one join, on root 2"
    );
    let sealed = world.sealed_epochs().await?;
    assert_eq!(sealed[3].initialMachineStateHash.0, computed);
    assert!(b_storage.settlement_info(0)?.is_none());
    assert!(b_storage.settlement_info(1)?.is_none());

    // A restart reads no image: neither a vanished path nor the template.
    drop(config);
    let vanished = scratch.path().join("vanished");
    drop(NodeConfig::setup_with(args(&world, HONEST, &vanished, b.state_dir.path())).await?);
    let template = program_path().join("machine-image");
    drop(NodeConfig::setup_with(args(&world, HONEST, &template, b.state_dir.path())).await?);
    assert!(b_storage.snapshot_hash(0, 0)?.is_none());
    Ok(())
}
