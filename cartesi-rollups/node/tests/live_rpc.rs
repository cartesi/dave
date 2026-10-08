// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The node's `eth_getLogs` splitting (chain.rs) against real providers:
//! a busy contract's logs over one ingestion chunk, and maximum-size inputs.
//! Providers change their caps and error shapes, so these are the evidence
//! that splitting still completes. They depend on third parties and spend
//! their quota, so they are ignored and stay out of `just check` and CI:
//! `just test-live-rpc` runs them with endpoints from the environment
//! (INFURA_MAINNET_URL, ALCHEMY_MAINNET_URL, INFURA_SEPOLIA_URL,
//! ALCHEMY_SEPOLIA_URL; any subset). Both ranges are history, so their
//! contents never change.

use std::{collections::BTreeSet, time::Instant};

use alloy::{
    primitives::{Address, address},
    providers::Provider,
    rpc::types::Filter,
};
use alloy_chains::NamedChain;
use cartesi_rollups_contracts::i_input_box::IInputBox::InputAdded;
use cartesi_sling_node::{chain::Chain, provider::create_rpc_provider};

/// USDC on Ethereum mainnet: about 30 logs per block.
const USDC: Address = address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
/// One ingestion chunk (INGEST_CHUNK_BLOCKS) of USDC history: past every
/// provider's result and response caps.
const USDC_RANGE: (u64, u64) = (23_000_000, 23_009_999);
/// USDC's logs in that range, as Infura and Alchemy both returned them.
const USDC_LOGS: usize = 349_084;

/// The rollups InputBox on Sepolia.
const INPUT_BOX: Address = address!("0xEbE9f4Dfc04ae10bBeE663859c3dc5A23f94eA3C");
/// A stub application on Sepolia (its code returns 32 zero bytes, so it is
/// never foreclosed) holding twelve maximum-size inputs: 65,216 zero payload
/// bytes each, eleven in block 11,852,174 and one in the next.
const STUB_APP: Address = address!("0x9c5666906fbca8d975ba5b7a8d6355274b879d8d");
const STUB_INPUTS: u64 = 12;
/// The largest input the InputBox accepts, encoded.
const MAX_ENCODED_INPUT: usize = 65_508;
/// Twenty thousand blocks ending at the inputs: wider than Infura's
/// 10,000-block cap, so the fetch must split.
const STUB_RANGE: (u64, u64) = (11_832_175, 11_852_175);

/// The chains configured in the environment, by variable name.
async fn chains(variables: &[&str], chain: NamedChain) -> Vec<(String, Chain)> {
    let mut chains = Vec::new();
    for variable in variables {
        let Ok(url) = std::env::var(variable) else {
            continue;
        };
        let url = url
            .parse()
            .unwrap_or_else(|_| panic!("{variable} is not a URL"));
        let provider = create_rpc_provider(&url, chain)
            .await
            .unwrap_or_else(|error| panic!("{variable}: {error:#}"));
        chains.push((variable.to_string(), Chain::new(provider)));
    }
    assert!(!chains.is_empty(), "set one of {variables:?}");
    chains
}

fn init_logging() {
    let _ = env_logger::builder()
        .filter_module("cartesi_sling_node::chain", log::LevelFilter::Debug)
        .try_init();
}

#[tokio::test]
#[ignore = "live providers: run `just test-live-rpc`"]
async fn a_busy_contracts_logs_over_one_chunk_are_complete() {
    init_logging();
    let mut answers = Vec::new();
    for (name, chain) in chains(
        &["INFURA_MAINNET_URL", "ALCHEMY_MAINNET_URL"],
        NamedChain::Mainnet,
    )
    .await
    {
        let started = Instant::now();
        let logs = chain
            .raw_logs(USDC, USDC_RANGE.0, USDC_RANGE.1)
            .await
            .unwrap_or_else(|error| panic!("{name}: {error:#}"));
        let keys: BTreeSet<(u64, u64)> = logs
            .iter()
            .map(|log| (log.block_number.unwrap(), log.log_index.unwrap()))
            .collect();
        assert_eq!(keys.len(), logs.len(), "{name} returned duplicate logs");
        assert_eq!(logs.len(), USDC_LOGS, "{name}: log count");
        assert!(
            keys.iter()
                .all(|(block, _)| (USDC_RANGE.0..=USDC_RANGE.1).contains(block)),
            "{name} returned logs outside the range"
        );
        println!("{name}: {} logs in {:.1?}", logs.len(), started.elapsed());
        answers.push((name, keys));
    }
    for pair in answers.windows(2) {
        assert!(
            pair[0].1 == pair[1].1,
            "{} and {} disagree: {} against {} logs",
            pair[0].0,
            pair[1].0,
            pair[0].1.len(),
            pair[1].1.len()
        );
    }
}

#[tokio::test]
#[ignore = "live providers: run `just test-live-rpc`"]
async fn maximum_size_inputs_are_complete() {
    init_logging();
    for (name, chain) in chains(
        &["INFURA_SEPOLIA_URL", "ALCHEMY_SEPOLIA_URL"],
        NamedChain::Sepolia,
    )
    .await
    {
        let started = Instant::now();
        let inputs = chain
            .decoded_logs::<InputAdded>(
                INPUT_BOX,
                Some(&STUB_APP.into_word().into()),
                STUB_RANGE.0,
                STUB_RANGE.1,
            )
            .await
            .unwrap_or_else(|error| panic!("{name}: {error:#}"));
        let indices: Vec<u64> = inputs.iter().map(|(input, _)| input.index.to()).collect();
        assert_eq!(indices, (0..STUB_INPUTS).collect::<Vec<_>>(), "{name}");
        assert!(
            inputs
                .iter()
                .all(|(input, _)| input.input.len() == MAX_ENCODED_INPUT),
            "{name} returned a truncated input"
        );
        println!(
            "{name}: {} inputs of {MAX_ENCODED_INPUT} bytes in {:.1?}",
            inputs.len(),
            started.elapsed()
        );
    }
}

/// The node's retry policy (provider.rs, RateLimitOnly) skips resending
/// Infura's result-count rejection by its wording, since Infura reuses its
/// rate-limit code for it. This pins the wording.
#[tokio::test]
#[ignore = "live providers: run `just test-live-rpc`"]
async fn infura_words_its_result_count_rejection_as_the_retry_policy_expects() {
    let Ok(url) = std::env::var("INFURA_MAINNET_URL") else {
        println!("INFURA_MAINNET_URL is unset: skipped");
        return;
    };
    let provider = create_rpc_provider(&url.parse().unwrap(), NamedChain::Mainnet)
        .await
        .unwrap_or_else(|error| panic!("INFURA_MAINNET_URL: {error:#}"));
    // About 30,000 logs: over the 10,000-result cap, light enough to answer.
    let filter = Filter::new()
        .address(USDC)
        .from_block(USDC_RANGE.0)
        .to_block(USDC_RANGE.0 + 999);
    let error = provider.get_logs(&filter).await.unwrap_err();
    let payload = error
        .as_error_resp()
        .unwrap_or_else(|| panic!("not an error response: {error}"));
    assert_eq!(payload.code, -32005, "{error}");
    assert!(
        payload.message.contains("query returned more than"),
        "{error}"
    );
}
