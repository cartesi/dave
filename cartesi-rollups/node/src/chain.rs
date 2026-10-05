// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The chain facade: one home for the node's read-side provider
//! policy. Ranged log fetching with bisection (descended from
//! https://github.com/cartesi/state-fold) and Latest/Finalized head
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
};
use anyhow::{Context, Result, anyhow, bail, ensure};
use log::debug;

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

/// Addresses per log filter, well under geth's default
/// `--rpc.logquerylimit` of 1,000.
const MAX_FILTER_ADDRESSES: usize = 100;

#[derive(Debug, Clone)]
pub struct Chain {
    provider: DynProvider,
}

impl Chain {
    pub fn new(provider: DynProvider) -> Self {
        Self { provider }
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

    /// Every log emitted by `address` in `[from, to]`, in the provider's
    /// order: the caller validates and orders them.
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
        self.decoded_logs_in_order(&filter, from, to).await
    }

    /// `E`-typed logs emitted by any of `addresses` in `[from, to]`, decoded
    /// and in chain order. One query per `MAX_FILTER_ADDRESSES` addresses:
    /// providers cap a filter's address list (geth at 1,000 by default).
    pub async fn decoded_logs_from_any<E: SolEvent>(
        &self,
        addresses: &[Address],
        from: u64,
        to: u64,
    ) -> Result<Vec<(E, Log)>> {
        let mut decoded = Vec::new();
        for chunk in addresses.chunks(MAX_FILTER_ADDRESSES) {
            let filter = Filter::new().address(chunk.to_vec()).event(E::SIGNATURE);
            decoded.extend(self.decoded_logs_in_order(&filter, from, to).await?);
        }
        decoded.sort_by_key(|(_, log)| (log.block_number, log.transaction_index, log.log_index));
        Ok(decoded)
    }

    async fn decoded_logs_in_order<E: SolEvent>(
        &self,
        filter: &Filter,
        from: u64,
        to: u64,
    ) -> Result<Vec<(E, Log)>> {
        let mut logs = self.logs_bisecting(filter, from, to).await?;
        // A response is not guaranteed to be in chain order, and ingestion
        // checks each input's index against its predecessor's: a reordered
        // response would fail every retry the same way. Ordering needs the
        // block number, which every mined log carries.
        if let Some(log) = logs.iter().find(|log| log.block_number.is_none()) {
            bail!(
                "a {} log from {} has no block number (transaction {:?}): an \
                 inconsistent response from the provider",
                E::SIGNATURE,
                log.address(),
                log.transaction_hash
            );
        }
        logs.sort_by_key(|log| (log.block_number, log.transaction_index, log.log_index));

        logs.into_iter()
            .map(|log| {
                let decoded = E::decode_log(&log.inner)?;
                Ok((decoded.data, log))
            })
            .collect()
    }

    /// Fetches `filter` over `[from, to]`, splitting a range wider than
    /// one block in two on any failure. Range, result-count and response
    /// size caps, and server or client timeouts, clear by narrowing; a
    /// rate limit or a dead provider looks the same once alloy's retries
    /// end, so they split too. A single block's logs are bounded by its
    /// gas, so a failure there aborts the call, and the caller retries
    /// next tick: a persistent error costs one left spine of sequential
    /// queries, about log2(width) + 1, never the whole tree. Iterative
    /// worklist, left half first, so logs come back in ascending block
    /// order.
    async fn logs_bisecting(&self, filter: &Filter, from: u64, to: u64) -> Result<Vec<Log>> {
        let mut pending = vec![(from, to)];
        let mut logs = Vec::new();

        while let Some((start, end)) = pending.pop() {
            let ranged = filter.clone().from_block(start).to_block(end);
            match self.provider.get_logs(&ranged).await {
                Ok(batch) => logs.extend(batch),
                Err(e) if start < end => {
                    debug!("get_logs over [{start}, {end}] failed, splitting it: {e}");
                    let middle = start + (1 + end - start) / 2 - 1;
                    // LIFO: push the right half first so the left half
                    // is fetched first, preserving chain order.
                    pending.push((middle + 1, end));
                    pending.push((start, middle));
                }
                Err(e) => return Err(e).context(format!("get_logs failed at block {start}")),
            }
        }

        Ok(logs)
    }
}

/// A mocked provider that records every JSON-RPC request it serves, for
/// tests that check which block a read is pinned to.
#[cfg(test)]
pub(crate) mod recording {
    use std::{
        sync::{Arc, Mutex},
        task::{Context, Poll},
    };

    use alloy::{
        providers::{DynProvider, Provider, ProviderBuilder},
        rpc::{
            client::RpcClient,
            json_rpc::{RequestPacket, ResponsePacket},
        },
        transports::{
            TransportError, TransportFut,
            mock::{Asserter, MockTransport},
        },
    };
    use tower::Service;

    pub(crate) type Requests = Arc<Mutex<Vec<serde_json::Value>>>;

    #[derive(Clone, Debug)]
    struct RecordingTransport {
        inner: MockTransport,
        requests: Requests,
    }

    impl Service<RequestPacket> for RecordingTransport {
        type Response = ResponsePacket;
        type Error = TransportError;
        type Future = TransportFut<'static>;

        fn poll_ready(&mut self, context: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
            self.inner.poll_ready(context)
        }

        fn call(&mut self, request: RequestPacket) -> Self::Future {
            self.requests
                .lock()
                .expect("request recording mutex is not poisoned")
                .push(serde_json::to_value(&request).expect("JSON-RPC request serializes"));
            self.inner.call(request)
        }
    }

    /// A provider answering from the asserter's queue, and the requests
    /// it was sent, in order.
    pub(crate) fn recording_provider() -> (DynProvider, Asserter, Requests) {
        let asserter = Asserter::new();
        let requests = Requests::default();
        let transport = RecordingTransport {
            inner: MockTransport::new(asserter.clone()),
            requests: Arc::clone(&requests),
        };
        let provider = ProviderBuilder::new()
            .connect_client(RpcClient::new(transport, true))
            .erased();
        (provider, asserter, requests)
    }
}

#[cfg(test)]
mod tests {
    use super::{Chain, ChainHead, recording::recording_provider};
    use alloy::{
        eips::BlockId,
        primitives::{Address, B256, Bytes, Log as PrimitiveLog, U256},
        providers::{Provider, ProviderBuilder},
        rpc::types::{Block, Log},
        sol_types::SolEvent,
    };
    use alloy_transport::mock::Asserter;
    use cartesi_rollups_contracts::i_input_box::IInputBox::InputAdded;

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
        (Chain::new(provider), asserter)
    }

    /// The `[fromBlock, toBlock]` of every get_logs request, in order.
    fn log_ranges(requests: &super::recording::Requests) -> Vec<(u64, u64)> {
        let block = |value: &serde_json::Value| {
            u64::from_str_radix(value.as_str().unwrap().trim_start_matches("0x"), 16).unwrap()
        };
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request["method"] == "eth_getLogs")
            .map(|request| {
                let filter = &request["params"][0];
                (block(&filter["fromBlock"]), block(&filter["toBlock"]))
            })
            .collect()
    }

    #[tokio::test]
    async fn get_logs_splits_on_any_failure_and_keeps_chain_order() {
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        // A timeout or an unlisted size cap carries no recognizable code.
        asserter.push_failure_msg("operation timed out");
        asserter.push_success(&vec![input_log(0, Some(1), 0)]);
        asserter.push_success(&vec![input_log(1, Some(6), 0)]);

        let logs = chain
            .decoded_logs::<InputAdded>(Address::ZERO, None, 0, 7)
            .await
            .unwrap();
        assert_eq!(indices(&logs), [0, 1]);
        assert_eq!(log_ranges(&requests), [(0, 7), (0, 3), (4, 7)]);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn a_persistent_get_logs_failure_costs_one_left_spine() {
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        for _ in 0..4 {
            asserter.push_failure_msg("rate limited");
        }

        let error = chain.raw_logs(Address::ZERO, 0, 7).await.unwrap_err();
        assert!(
            format!("{error:#}").contains("failed at block 0"),
            "unexpected error: {error:#}"
        );
        assert_eq!(log_ranges(&requests), [(0, 7), (0, 3), (0, 1), (0, 0)]);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn a_failing_single_block_aborts_after_the_logs_before_it() {
        let (provider, asserter, requests) = recording_provider();
        let chain = Chain::new(provider);
        asserter.push_failure_msg("too large");
        asserter.push_success(&Vec::<Log>::new());
        asserter.push_failure_msg("too large");
        asserter.push_failure_msg("too large");
        asserter.push_success(&Vec::<Log>::new());
        asserter.push_failure_msg("lagging backend");

        let error = chain.raw_logs(Address::ZERO, 0, 7).await.unwrap_err();
        assert!(
            format!("{error:#}").contains("failed at block 5"),
            "unexpected error: {error:#}"
        );
        assert_eq!(
            log_ranges(&requests),
            [(0, 7), (0, 3), (4, 7), (4, 5), (4, 4), (5, 5)]
        );
        assert!(asserter.read_q().is_empty());
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

    fn input_log(index: u64, block: Option<u64>, log_index: u64) -> Log {
        let event = InputAdded {
            appContract: Address::ZERO,
            index: U256::from(index),
            input: Bytes::new(),
        };
        Log {
            inner: PrimitiveLog {
                address: Address::ZERO,
                data: event.encode_log_data(),
            },
            block_number: block,
            transaction_index: Some(log_index),
            log_index: Some(log_index),
            ..Default::default()
        }
    }

    fn indices(logs: &[(InputAdded, Log)]) -> Vec<u64> {
        logs.iter()
            .map(|(event, _)| event.index.to::<u64>())
            .collect()
    }

    #[tokio::test]
    async fn decoded_logs_come_back_in_chain_order() {
        let (chain, asserter) = mocked_chain();
        asserter.push_success(&vec![
            input_log(3, Some(9), 0),
            input_log(1, Some(8), 4),
            input_log(2, Some(8), 5),
            input_log(0, Some(8), 1),
        ]);

        let logs = chain
            .decoded_logs::<InputAdded>(Address::ZERO, None, 1, 10)
            .await
            .unwrap();
        assert_eq!(indices(&logs), [0, 1, 2, 3]);
    }

    #[tokio::test]
    async fn a_decoded_log_without_block_number_is_an_error() {
        let (chain, asserter) = mocked_chain();
        asserter.push_success(&vec![input_log(0, Some(8), 0), input_log(1, None, 1)]);

        let error = chain
            .decoded_logs::<InputAdded>(Address::ZERO, None, 1, 10)
            .await
            .unwrap_err();
        assert!(
            error.to_string().contains("has no block number"),
            "unexpected error: {error:#}"
        );
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
