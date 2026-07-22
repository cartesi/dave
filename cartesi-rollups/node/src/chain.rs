// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The chain facade: one home for the node's read-side provider
//! policy. Ranged log fetching with bisection-on-too-large (descended
//! from https://github.com/cartesi/state-fold), the provider-specific
//! long-range error codes that trigger it, and Latest/Finalized head
//! sampling live here, so workers stop threading provider quirks
//! through their constructors.

use alloy::{
    eips::{
        BlockId, BlockNumberOrTag,
        BlockNumberOrTag::{Finalized, Latest},
    },
    primitives::{Address, B256},
    providers::{DynProvider, Provider},
    rpc::types::{Filter, Log, Topic},
    sol_types::SolEvent,
    transports::TransportError,
};
use anyhow::{Result, anyhow, ensure};

/// A block-number/hash pair that identifies one chain observation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ChainHead {
    /// The block height reported with `hash`.
    pub number: u64,
    /// The exact block hash reported at `number`.
    pub hash: B256,
}

impl ChainHead {
    /// An EIP-1898 identifier for point reads at this sampled hash.
    ///
    /// The hash is deliberately not required to remain canonical.
    /// Unfinalized observations are scratch: a reorg may make an
    /// action stale, and the contract revalidates it at execution.
    pub const fn block_id(self) -> BlockId {
        BlockId::hash(self.hash)
    }
}

#[derive(Debug, Clone)]
pub struct Chain {
    provider: DynProvider,
    long_block_range_error_codes: Vec<String>,
}

impl Chain {
    pub fn new(provider: DynProvider, long_block_range_error_codes: Vec<String>) -> Self {
        Self {
            provider,
            long_block_range_error_codes,
        }
    }

    /// The underlying provider, for contract instances and pinned
    /// point reads; policy-bearing access goes through the methods
    /// below.
    pub fn provider(&self) -> &DynProvider {
        &self.provider
    }

    pub async fn latest_block_number(&self) -> Result<u64> {
        Ok(self
            .provider
            .get_block(Latest.into())
            .await?
            .ok_or_else(|| anyhow!("provider has no latest block"))?
            .header
            .number)
    }

    pub async fn finalized_block_number(&self) -> Result<u64> {
        Ok(self
            .provider
            .get_block(Finalized.into())
            .await?
            .ok_or_else(|| anyhow!("provider has no finalized block"))?
            .header
            .number)
    }

    /// Sample Latest once and retain both coordinates needed to pin
    /// the rest of an observation.
    pub async fn latest_head(&self) -> Result<ChainHead> {
        self.tagged_head(Latest, "latest").await
    }

    /// Sample Finalized once, including its hash so logs at the durable
    /// boundary can be checked before persistence.
    pub async fn finalized_head(&self) -> Result<ChainHead> {
        self.tagged_head(Finalized, "finalized").await
    }

    async fn tagged_head(&self, tag: BlockNumberOrTag, label: &str) -> Result<ChainHead> {
        let block = self
            .provider
            .get_block(tag.into())
            .await?
            .ok_or_else(|| anyhow!("provider has no {label} block"))?;
        let head = ChainHead {
            number: block.header.number,
            hash: block.header.hash,
        };
        ensure!(
            head.hash != B256::ZERO,
            "provider returned a {label} block with a zero hash"
        );
        Ok(head)
    }

    /// Every log emitted by `address` in `[from, to]`, in chain order.
    pub async fn raw_logs(&self, address: Address, from: u64, to: u64) -> Result<Vec<Log>> {
        let filter = Filter::new().address(address);
        self.logs_bisecting(&filter, from, to).await
    }

    /// `E`-typed logs emitted by `address` in `[from, to]`, optionally
    /// narrowed by `topic1`, decoded and in chain order.
    pub async fn decoded_logs<E: SolEvent>(
        &self,
        address: Address,
        topic1: Option<&Topic>,
        from: u64,
        to: u64,
    ) -> Result<Vec<(E, Log)>> {
        let mut filter = Filter::new().address(address).event(E::SIGNATURE);
        if let Some(topic) = topic1 {
            filter = filter.topic1(topic.clone());
        }

        self.logs_bisecting(&filter, from, to)
            .await?
            .into_iter()
            .map(|log| {
                let decoded = E::decode_log(&log.inner)?;
                Ok((decoded.data, log))
            })
            .collect()
    }

    /// Fetches `filter` over `[from, to]`, splitting the range in two
    /// whenever the provider rejects it as too large (gateways cap
    /// get_logs spans; the rejection surfaces as one of the configured
    /// error codes). Iterative worklist, left half first, so logs come
    /// back in ascending block order.
    async fn logs_bisecting(&self, filter: &Filter, from: u64, to: u64) -> Result<Vec<Log>> {
        let mut pending = vec![(from, to)];
        let mut logs = Vec::new();
        let mut errors: Vec<TransportError> = Vec::new();

        while let Some((start, end)) = pending.pop() {
            let ranged = filter.clone().from_block(start).to_block(end);
            match self.provider.get_logs(&ranged).await {
                Ok(batch) => logs.extend(batch),
                Err(e) if start < end && self.is_long_range_rejection(&e) => {
                    let middle = start + (1 + end - start) / 2 - 1;
                    // LIFO: push the right half first so the left half
                    // is fetched first, preserving chain order.
                    pending.push((middle + 1, end));
                    pending.push((start, middle));
                }
                Err(e) => errors.push(e),
            }
        }

        if errors.is_empty() {
            Ok(logs)
        } else {
            Err(anyhow!("get_logs failed: {errors:?}"))
        }
    }

    fn is_long_range_rejection(&self, err: &TransportError) -> bool {
        matches_any_code(&self.long_block_range_error_codes, err)
    }
}

/// Substring match against the error's Debug rendering: provider
/// error shapes vary too much for structured matching, and the codes
/// are operator-supplied configuration.
fn matches_any_code(codes: &[String], err: &impl std::fmt::Debug) -> bool {
    let rendered = format!("{:?}", err);
    codes.iter().any(|code| rendered.contains(code))
}

#[cfg(test)]
mod tests {
    use super::{Chain, ChainHead, matches_any_code};
    use alloy::{
        eips::BlockId,
        primitives::B256,
        providers::{Provider, ProviderBuilder},
        rpc::types::Block,
    };
    use alloy_transport::mock::Asserter;

    fn hash(byte: u8) -> B256 {
        B256::repeat_byte(byte)
    }

    fn head(number: u64, byte: u8) -> ChainHead {
        ChainHead {
            number,
            hash: hash(byte),
        }
    }

    fn block(head: ChainHead, parent_hash: B256) -> Block {
        let mut block: Block = Block::default();
        block.header.hash = head.hash;
        block.header.inner.number = head.number;
        block.header.inner.parent_hash = parent_hash;
        block
    }

    fn mocked_chain() -> (Chain, Asserter) {
        let asserter = Asserter::new();
        let provider = ProviderBuilder::new()
            .connect_mocked_client(asserter.clone())
            .erased();
        (Chain::new(provider, Vec::new()), asserter)
    }

    #[test]
    fn long_range_rejection_matches_by_error_code() {
        let s = r###"Error: HTTP error 400 with body: {"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"You can make eth_getLogs requests with up to a 10000 block range. Based on your parameters, this block range should work: [0x1754746, 0x1756e55]"}}"###;

        let codes: Vec<String> = ["-32005", "-32600", "-32602", "-32616"]
            .iter()
            .map(|s| s.to_string())
            .collect();

        assert!(matches_any_code(&codes, &std::io::Error::other(s)));
        assert!(!matches_any_code(
            &codes,
            &std::io::Error::other("no code here")
        ));
        assert!(!matches_any_code(&[], &std::io::Error::other(s)));
    }

    #[test]
    fn chain_head_uses_noncanonical_eip_1898_id() {
        let head = head(42, 0x42);
        assert_eq!(head.block_id(), BlockId::hash(head.hash));
    }

    #[tokio::test]
    async fn latest_head_samples_number_and_hash() {
        let (chain, asserter) = mocked_chain();
        let expected = head(42, 0x42);
        asserter.push_success(&Some(block(expected, hash(0x41))));

        assert_eq!(chain.latest_head().await.unwrap(), expected);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn finalized_head_samples_number_and_hash() {
        let (chain, asserter) = mocked_chain();
        let expected = head(37, 0x37);
        asserter.push_success(&Some(block(expected, hash(0x36))));

        assert_eq!(chain.finalized_head().await.unwrap(), expected);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn finalized_head_fails_closed_on_missing_block() {
        let (chain, asserter) = mocked_chain();
        let missing: Option<Block> = None;
        asserter.push_success(&missing);

        let error = chain.finalized_head().await.unwrap_err();
        assert!(error.to_string().contains("no finalized block"));
    }

    #[tokio::test]
    async fn latest_head_fails_closed_on_missing_block_or_rpc_error() {
        let (missing_chain, missing_asserter) = mocked_chain();
        let missing: Option<Block> = None;
        missing_asserter.push_success(&missing);
        let error = missing_chain.latest_head().await.unwrap_err();
        assert!(error.to_string().contains("no latest block"));

        let (failed_chain, failed_asserter) = mocked_chain();
        failed_asserter.push_failure_msg("latest unavailable");
        assert!(failed_chain.latest_head().await.is_err());
    }

    #[tokio::test]
    async fn latest_head_rejects_zero_hash() {
        let (chain, asserter) = mocked_chain();
        let invalid = ChainHead {
            number: 42,
            hash: B256::ZERO,
        };
        asserter.push_success(&Some(block(invalid, hash(0x41))));

        let error = chain.latest_head().await.unwrap_err();
        assert!(error.to_string().contains("zero hash"));
    }
}
