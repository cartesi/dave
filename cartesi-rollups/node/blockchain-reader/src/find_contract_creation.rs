// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::{
    eips::BlockId,
    primitives::Address,
    providers::Provider,
    transports::{RpcError, TransportErrorKind},
};

/// Binary‑searches for the first block in which `addr`’s code is non‑empty.
/// Returns the block number, or bubbles up the provider’s error.
pub async fn find_contract_creation_block(
    provider: &impl Provider,
    addr: Address,
) -> Result<u64, RpcError<TransportErrorKind>> {
    // upper bound
    let mut low = 0u64;
    let mut high = provider.get_block_number().await?;

    // while range > 0
    while low < high {
        // safe mid = low + (high - low) / 2
        let mid = low + (high - low) / 2;
        let code = provider
            .get_code_at(addr)
            .block_id(BlockId::Number(mid.into()))
            .await?;
        if code.0.is_empty() {
            // creation must be after mid
            low = mid + 1;
        } else {
            // creation is at or before mid
            high = mid;
        }
    }

    Ok(low)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_utils::*;

    use alloy::primitives::U256;
    use alloy::{providers::ProviderBuilder, transports::mock::Asserter};

    /// If there are zero blocks (i.e. latest = 0), we return 0 immediately.
    #[tokio::test]
    async fn test_genesis() {
        let addr = Address::default();
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new().on_mocked_client(asserter.clone());

        // get_block_number → 0
        asserter.push_success(&U256::from(0));

        let block = find_contract_creation_block(&provider, addr).await.unwrap();
        assert_eq!(block, 0);
    }

    /// Simulate code appearing first at block 3 when latest=4.
    #[tokio::test]
    async fn test_binary_search() {
        let addr = Address::default();
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new().on_mocked_client(asserter.clone());

        // 1) get_block_number → 4
        asserter.push_success(&U256::from(4));
        // 2) mid = 0 + (4−0)/2 = 2 → get_code(2) = empty
        asserter.push_success(&"0x");
        // 3) new range [3..4], mid = 3 + (4−3)/2 = 3 → get_code(3) = non‑empty
        asserter.push_success(&"0x01");

        let block = find_contract_creation_block(&provider, addr).await.unwrap();
        assert_eq!(block, 3);
    }

    #[tokio::test]
    async fn test_predeployed_contracts_creation_blocks() {
        // spawn Anvil + provider + the two contract addrs
        let (_anvil, provider, input_box, consensus, _digest) = spawn_anvil_and_provider();

        // find creation block for input_box
        let input_block = find_contract_creation_block(&provider, input_box)
            .await
            .expect("failed to find input_box creation block");
        // one block before should have no code
        let prev_input = provider
            .get_code_at(input_box)
            .block_id(BlockId::Number((input_block - 1).into()))
            .await
            .unwrap();
        assert!(prev_input.0.is_empty(), "input_box existed too early");

        // find creation block for consensus
        let consensus_block = find_contract_creation_block(&provider, consensus)
            .await
            .expect("failed to find consensus creation block");
        // one block before should have no code
        let prev_consensus = provider
            .get_code_at(consensus)
            .block_id(BlockId::Number((consensus_block - 1).into()))
            .await
            .unwrap();
        assert!(prev_consensus.0.is_empty(), "consensus existed too early");
    }
}
