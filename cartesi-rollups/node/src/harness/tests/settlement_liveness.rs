//! Settlement sender outages, observed independently through the public RPC views.

use super::*;
use cartesi_dave_contracts::dave_consensus::DaveConsensus as C;
use std::process::Command;

async fn settlement_world(sentries: &[usize], period: u64) -> Result<World> {
    let world = World::spawn(sentries, period).await?;
    // Protocol clocks count blocks. Keep synthetic mining from putting a newly
    // built bundle's timestamps ahead of the observer's real wall clock.
    world.provider.anvil_set_block_timestamp_interval(0).await?;
    Ok(world)
}

fn observer(world: &World, state: &std::path::Path, expected: i32) -> Result<serde_json::Value> {
    let output = Command::new("python3")
        .arg("../../script/settlement-watch.py")
        .args(["--rpc-url", &world.anvil.endpoint()])
        .args(["--consensus", &world.book.consensus.to_string()])
        .args(["--chain-id", &world.anvil.chain_id().to_string()])
        .arg("--state-file")
        .arg(state)
        .args(["--grace-blocks", "4", "--block", "latest"])
        // The deterministic devnet's timestamps deliberately predate wall time.
        .args(["--max-head-age-seconds", "9999999999"])
        .output()?;
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).with_context(|| {
        format!(
            "observer stdout: {} stderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })?;
    eprintln!("settlement observer: {report}");
    ensure!(
        output.status.code() == Some(expected),
        "unexpected observer exit: {report}"
    );
    Ok(report)
}

fn proof(settlement: &crate::storage::Settlement) -> C::MachineValidityProof {
    let leaf = |p: &crate::storage::LeafProof| C::LeafProof {
        dataBlock: p.data_block.into(),
        siblings: p
            .siblings
            .inner()
            .iter()
            .map(|hash| (*hash).into())
            .collect(),
    };
    let p = &settlement.machine_validity_proof;
    C::MachineValidityProof {
        iflagsYProof: leaf(&p.iflags_y_proof),
        htifTohostProof: leaf(&p.htif_tohost_proof),
        txBufferProof: leaf(&p.tx_buffer_proof),
    }
}

fn recovery_evidence(node: &Node, epoch: u64) -> Result<serde_json::Value> {
    let output = Command::new("python3")
        .arg("../../script/settlement-recover.py")
        .args(["--action", "export", "--epoch", &epoch.to_string()])
        .arg("--state-dir")
        .arg(node.state_dir.path())
        .output()?;
    ensure!(
        output.status.success(),
        "evidence export failed: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    Ok(serde_json::from_slice(&output.stdout)?)
}

fn operator_recovery(
    world: &World,
    state: &std::path::Path,
    evidence: &serde_json::Value,
) -> Result<alloy::primitives::B256> {
    use std::{io::Write, process::Stdio};
    let path = state.with_extension("evidence.json");
    std::fs::write(&path, serde_json::to_vec(evidence)?)?;
    let mut child = Command::new("python3")
        .arg("../../script/settlement-operator.py")
        .args(["--rpc-url", &world.anvil.endpoint()])
        .args(["--consensus", &world.book.consensus.to_string()])
        .args(["--chain-id", &world.anvil.chain_id().to_string()])
        .arg("--state-file")
        .arg(state)
        .args([
            "--grace-blocks",
            "4",
            "--block",
            "latest",
            "--max-head-age-seconds",
            "9999999999",
        ])
        .arg("--evidence")
        .arg(path)
        .args(["--from", &world.address(OPERATOR).to_string(), "--unlocked"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(b"yes\nyes\n")?;
    let output = child.wait_with_output()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    eprintln!(
        "operator wrapper stdout: {stdout}\nstderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    ensure!(output.status.success(), "operator recovery failed");
    let submitted = stdout
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|value| value["verdict"] == "submitted")
        .context("no submission record")?;
    Ok(submitted["transaction_hash"]
        .as_str()
        .context("missing transaction hash")?
        .parse()?)
}

async fn mine_transaction(world: &mut World, hash: alloy::primitives::B256) -> Result<()> {
    world.mine(1).await?;
    ensure!(
        world
            .provider
            .get_transaction_receipt(hash)
            .await?
            .context("missing receipt")?
            .status(),
        "recovery transaction reverted"
    );
    Ok(())
}

#[tokio::test]
#[ignore = "needs the devnet bundle and echo image"]
async fn settlement_sender_outage_before_staging_is_detected_and_another_caller_recovers()
-> Result<()> {
    let mut world = settlement_world(&[], 0).await?;
    let mut sender = world.honest_node().await?;
    world.add_input(b"input before outage".to_vec()).await?;
    settle(&mut sender, &mut world, 0).await?;
    join_and_close(&mut sender, &mut world).await?;
    // No more ticks: the original sender is down, not merely missing one transaction.
    drop(sender);
    let reports = tempfile::tempdir()?;
    let state = reports.path().join("observer.json");
    assert_eq!(observer(&world, &state, 0)?["phase"], "winner_unstaged");
    world
        .add_input(b"input while settlement is down".to_vec())
        .await?;
    world.mine(4).await?;
    assert_eq!(observer(&world, &state, 2)?["verdict"], "stalled");
    assert_eq!(world.sealed_epochs().await?.len(), 2);

    // A fresh runner derives its own material; it does not tick its sender.
    let mut verifier = world.node(8).await?;
    verifier.roll(&mut world, 1).await?;
    let settlement = Storage::new(verifier.state_dir.path())?
        .settlement_info(1)?
        .unwrap();
    let stage = world.consensus().canStageTournamentResult().call().await?;
    assert!(settlement.machine_validity_proof.settles());
    assert_eq!(stage.winnerCommitment, settlement.computation_hash.data());
    assert_eq!(
        stage.winnerPostEpochMachineStateHash,
        FixedBytes::from(settlement.final_state)
    );
    let consensus = C::new(world.book.consensus, world.operator.clone());
    assert!(
        !consensus
            .isOutputsMerkleRootValid(world.book.app, settlement.outputs_merkle_root().into())
            .call()
            .await?
    );
    let evidence = recovery_evidence(&verifier, 1)?;
    let hash = operator_recovery(&world, &state, &evidence)?;
    mine_transaction(&mut world, hash).await?;
    assert_eq!(observer(&world, &state, 0)?["phase"], "acceptance_ready");
    world.mine(4).await?;
    let hash = operator_recovery(&world, &state, &evidence)?;
    mine_transaction(&mut world, hash).await?;
    let report = observer(&world, &state, 0)?;
    assert_eq!(report["epoch"], 2);
    assert_eq!(report["phase"], "tournament_in_progress");
    let epochs = world.sealed_epochs().await?;
    assert_eq!(epochs.len(), 3);
    assert_eq!(epochs[2].inputIndexUpperBound, U256::from(2));
    assert!(
        consensus
            .isOutputsMerkleRootValid(world.book.app, settlement.outputs_merkle_root().into())
            .call()
            .await?
    );
    assert_eq!(world.honest_calls(STAGE).len(), 1);
    assert_eq!(world.honest_calls(ACCEPT).len(), 1);
    eprintln!(
        "sender outage recovered by operator key 9, not sender key 0\n{}",
        world.trace()
    );
    Ok(())
}

#[tokio::test]
#[ignore = "needs the devnet bundle and echo image"]
async fn settlement_sender_outage_after_staging_respects_wait_then_recovers() -> Result<()> {
    const PERIOD: u64 = 30;
    let mut world = settlement_world(&[], PERIOD).await?;
    let mut sender = world.honest_node().await?;
    join_and_close(&mut sender, &mut world).await?;
    sender
        .run_until(&mut world, ROUNDS, |world, _| {
            Ok(!world.honest_calls(STAGE).is_empty())
        })
        .await?;
    drop(sender);
    let reports = tempfile::tempdir()?;
    let state = reports.path().join("observer.json");
    assert_eq!(observer(&world, &state, 0)?["phase"], "staging_wait");
    let consensus = C::new(world.book.consensus, world.operator.clone());
    assert!(
        consensus
            .acceptStagedTournamentResult(U256::ZERO)
            .call()
            .await
            .is_err()
    );
    let staged = world.consensus().getCurrentSealedEpoch().call().await?;
    world
        .mine_to(u64::try_from(staged.stagingBlockNumber)? + PERIOD)
        .await?;
    assert_eq!(observer(&world, &state, 0)?["phase"], "acceptance_ready");
    world.mine(4).await?;
    assert_eq!(observer(&world, &state, 2)?["verdict"], "stalled");
    assert_eq!(world.sealed_epochs().await?.len(), 1);
    let pending = consensus
        .acceptStagedTournamentResult(U256::ZERO)
        .send()
        .await?;
    mine_transaction(&mut world, *pending.tx_hash()).await?;
    assert_eq!(observer(&world, &state, 0)?["epoch"], 1);
    assert!(world.honest_calls(ACCEPT).is_empty());
    Ok(())
}

#[tokio::test]
#[ignore = "needs the devnet bundle and echo image"]
async fn settlement_observer_distinguishes_open_tournament_failed_root_and_foreclosure()
-> Result<()> {
    let mut world = settlement_world(&[], 0).await?;
    let reports = tempfile::tempdir()?;
    let state = reports.path().join("observer.json");
    assert_eq!(
        observer(&world, &state, 0)?["phase"],
        "tournament_in_progress"
    );
    world.mine(4).await?;
    assert_eq!(observer(&world, &state, 0)?["verdict"], "waiting");
    let close = world.root_closes_at().await?;
    world.mine_to(close).await?;
    assert_eq!(observer(&world, &state, 3)?["phase"], "root_failed");
    foreclose(&mut world).await?;
    assert_eq!(observer(&world, &state, 0)?["phase"], "foreclosed");
    Ok(())
}

#[tokio::test]
#[ignore = "needs the devnet bundle"]
async fn settlement_observer_never_treats_a_terminal_winner_as_safe_to_stage() -> Result<()> {
    let template_dir = tempfile::tempdir()?;
    let template = template_dir.path().join("machine");
    let mut machine = crate::test_machine::yield_guest(
        u64::MAX,
        &[
            crate::test_machine::manual_yield(RX_ACCEPTED, 0),
            crate::test_machine::halt(),
        ],
    )?;
    machine.store(&template)?;
    drop(machine);
    let mut world = World::spawn_on_template(&[], 0, template).await?;
    world.provider.anvil_set_block_timestamp_interval(0).await?;
    let mut node = world.honest_node().await?;
    world.add_input(vec![1]).await?;
    settle(&mut node, &mut world, 0).await?;
    join_and_close(&mut node, &mut world).await?;
    let settlement = Storage::new(node.state_dir.path())?
        .settlement_info(1)?
        .unwrap();
    assert!(!settlement.machine_validity_proof.settles());
    let reports = tempfile::tempdir()?;
    let state = reports.path().join("observer.json");
    assert_eq!(observer(&world, &state, 0)?["phase"], "winner_unstaged");
    world.mine(4).await?;
    assert_eq!(observer(&world, &state, 2)?["verdict"], "stalled");
    // The same public phase can be an outage or an unstageable true result.
    // The observer must not sign; a contract call independently rejects this proof.
    assert!(
        world
            .consensus()
            .stageTournamentResult(U256::from(1), proof(&settlement))
            .call()
            .await
            .is_err()
    );
    assert_eq!(world.sealed_epochs().await?.len(), 2);
    Ok(())
}
