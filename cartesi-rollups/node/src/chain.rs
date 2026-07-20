// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The chain facade: one home for the node's read-side provider
//! policy. Ranged log fetching with bisection-on-too-large (descended
//! from https://github.com/cartesi/state-fold), the provider-specific
//! long-range error codes that trigger it, and Latest/Finalized head
//! sampling live here, so workers stop threading provider quirks
//! through their constructors.

use alloy::{
    eips::BlockNumberOrTag::{Finalized, Latest},
    primitives::Address,
    providers::{DynProvider, Provider},
    rpc::types::{Filter, Log, Topic},
    sol_types::SolEvent,
    transports::TransportError,
};
use anyhow::{Result, anyhow};

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
    use super::matches_any_code;

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
}
