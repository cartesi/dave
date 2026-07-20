// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! Records a devnet chain's complete raw log range, plus the timestamp
//! of every block that carries a log, as a JSON fixture. Deliberately
//! raw and unfiltered: the tournament-state fold (workstream 5 of
//! docs/plans/node-refactor.md) decodes fixtures through the same
//! bindings the production fetcher uses, so a recording cannot bake in
//! decoding assumptions. Invoked by the e2e harness when
//! RECORD_CHAIN_FIXTURE is set (see prt/tests/rollups/test_env.lua).

use anyhow::{Context, Result};
use clap::Parser;
use std::collections::BTreeMap;
use std::path::PathBuf;

use alloy::eips::BlockNumberOrTag;
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::{Filter, Log};

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "http://127.0.0.1:8545")]
    rpc_url: String,

    /// Fixture destination (JSON).
    #[arg(long)]
    out: PathBuf,

    #[arg(long, default_value_t = 0)]
    from_block: u64,

    /// Free-form context stored in the fixture (scenario name etc).
    #[arg(long)]
    note: Option<String>,
}

#[derive(serde::Serialize)]
struct Recording {
    note: Option<String>,
    chain_id: u64,
    from_block: u64,
    to_block: u64,
    /// Timestamps of every block carrying at least one log: the
    /// clock-derivability lead needs them alongside the events.
    block_timestamps: BTreeMap<u64, u64>,
    logs: Vec<Log>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let provider = ProviderBuilder::new().connect_http(args.rpc_url.parse()?);

    let chain_id = provider.get_chain_id().await?;
    let to_block = provider.get_block_number().await?;
    let filter = Filter::new().from_block(args.from_block).to_block(to_block);
    let logs = provider.get_logs(&filter).await?;

    let mut block_timestamps = BTreeMap::new();
    for number in logs.iter().filter_map(|log| log.block_number) {
        if let std::collections::btree_map::Entry::Vacant(entry) = block_timestamps.entry(number) {
            let block = provider
                .get_block_by_number(BlockNumberOrTag::Number(number))
                .await?
                .with_context(|| format!("block {number} vanished mid-recording"))?;
            entry.insert(block.header.timestamp);
        }
    }

    let recording = Recording {
        note: args.note,
        chain_id,
        from_block: args.from_block,
        to_block,
        block_timestamps,
        logs,
    };
    if let Some(parent) = args.out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&args.out, serde_json::to_vec_pretty(&recording)?)?;
    eprintln!(
        "recorded {} logs through block {} to {}",
        recording.logs.len(),
        to_block,
        args.out.display()
    );
    Ok(())
}
