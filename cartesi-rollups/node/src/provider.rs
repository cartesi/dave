// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::args::SignerArgs;
use crate::kms::{CommonSignature, KmsSignerBuilder};
use alloy::{
    eips::{eip1559::Eip1559Estimation, eip2718::Encodable2718},
    network::{Ethereum, EthereumWallet, NetworkWallet, TransactionBuilder},
    primitives::{Address, B256, keccak256},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::{client::RpcClient, types::TransactionRequest},
    signers::local::PrivateKeySigner,
    transports::http::{Http, reqwest::Url},
};
use alloy_chains::NamedChain;
use alloy_transport::{TransportError, layers::RetryBackoffLayer};
use anyhow::{Context, Result, ensure};
use log::{debug, trace, warn};
use std::{fs, str::FromStr, time::Duration};

pub(crate) async fn create_signer(
    chain_id: NamedChain,
    signer_args: &SignerArgs,
) -> (Address, EthereumWallet) {
    let signer: Box<CommonSignature> = match signer_args {
        SignerArgs::Pk {
            web3_private_key,
            web3_private_key_file,
        } => {
            let pk = if let Some(file) = web3_private_key_file {
                fs::read_to_string(file)
                    .expect("fail to read key from file")
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string()
            } else {
                web3_private_key.clone().unwrap()
            };

            let local_signer =
                PrivateKeySigner::from_str(&pk).expect("could not create private key signer");

            Box::new(local_signer)
        }
        SignerArgs::AwsKms {
            aws_kms_key_id,
            aws_kms_key_id_file,
            aws_endpoint_url,
            aws_region,
            ..
        } => {
            let endpoint_url = aws_endpoint_url
                .clone()
                .unwrap_or_else(|| format!("https://kms.{}.amazonaws.com", aws_region));

            let key_id = if let Some(file) = aws_kms_key_id_file {
                fs::read_to_string(file)
                    .expect("fail to read key from kws file")
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string()
            } else {
                aws_kms_key_id.clone().unwrap()
            };

            let kms_signer = KmsSignerBuilder::new(&key_id, chain_id.into())
                .with_region(aws_region)
                .with_endpoint(&endpoint_url)
                .build()
                .await
                .expect("could not create Kms signer");

            Box::new(kms_signer)
        }
    };

    let wallet = EthereumWallet::from(signer);
    let wallet_address =
        <EthereumWallet as NetworkWallet<Ethereum>>::default_signer_address(&wallet);

    (wallet_address, wallet)
}

async fn create_client(url: &Url) -> RpcClient {
    // let throttle = alloy_transport::layers::ThrottleLayer::new(20);

    let retry = RetryBackoffLayer::new(
        5,   // max_rate_limit_retries
        200, // initial_backoff_ms
        500, // compute_units_per_sec
    );

    let h2_client = reqwest::Client::builder()
        .http2_adaptive_window(true)
        .http2_keep_alive_interval(Duration::from_secs(30))
        .http2_keep_alive_timeout(Duration::from_secs(10))
        .http2_keep_alive_while_idle(true)
        .pool_max_idle_per_host(1)
        .pool_idle_timeout(Duration::from_secs(60))
        .tcp_keepalive(Some(Duration::from_secs(60)))
        .timeout(Duration::from_secs(20))
        .build()
        .expect("failed to build reqwest client");
    let transport = Http::with_client(h2_client, url.clone());
    let is_local = transport.guess_local();

    RpcClient::builder()
        // .layer(throttle)
        .layer(retry)
        .transport(transport, is_local)
}

/// Build a signerless provider. Transaction filling is intentionally disabled:
/// every node mutation is fully specified and signed by [`TransactionLane`].
pub async fn create_rpc_provider(url: &Url, arg_chain_id: NamedChain) -> DynProvider {
    let client = create_client(url).await;
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .with_chain(arg_chain_id)
        .connect_client(client);

    let chain_id = provider
        .get_chain_id()
        .await
        .expect("failed to get chain_id from provider");
    assert_eq!(
        chain_id, arg_chain_id as u64,
        "provider chain_id does not match args chain_id"
    );

    provider.erased()
}

/// The node signer's stateless transaction lane.
///
/// Nonces come from the account's mined count at the `latest` block,
/// fees are the fresh market quote at every submission, and the
/// mempool (or block builder) stays the sole authority on duplicates
/// and replacements: "already known" and "replacement underpriced"
/// are benign verdicts, and a stale nonce means inclusion advanced
/// past the plan and the next tick replans. The lane holds no mutable
/// state - callers re-derive and resubmit their complete intent every
/// tick (docs/plans/self-healing-batch-submission.md), so anything a
/// lost response could forget is rebuilt from observation.
///
/// Submissions flow from the epoch manager's serial loop; the lane
/// has no internal serialization, and concurrent waves would only
/// race nonces in the pool - harmless, but noisy.
#[derive(Clone, Debug)]
pub struct TransactionLane {
    read_provider: DynProvider,
    submit_provider: DynProvider,
    signer_address: Address,
    chain_id: u64,
    wallet: EthereumWallet,
}

impl TransactionLane {
    pub fn new(
        read_provider: DynProvider,
        submit_provider: DynProvider,
        chain_id: u64,
        wallet: EthereumWallet,
    ) -> Self {
        let signer_address =
            <EthereumWallet as NetworkWallet<Ethereum>>::default_signer_address(&wallet);
        Self {
            read_provider,
            submit_provider,
            signer_address,
            chain_id,
            wallet,
        }
    }

    pub const fn signer_address(&self) -> Address {
        self.signer_address
    }

    /// Submit one fully specified call at the base nonce, failing on
    /// a transport or signing error. Pool verdicts short of failure
    /// stay benign, as in a wave.
    pub async fn submit(&self, label: &str, request: TransactionRequest) -> Result<SendReport> {
        let mut reports = self.submit_wave(vec![(label.to_string(), request)]).await?;
        let report = reports.pop().expect("one request yields one report");
        ensure!(
            report.verdict != SendVerdict::Failed,
            "failed to submit {} transaction {} at nonce {}",
            report.label,
            report.tx_hash,
            report.nonce
        );
        Ok(report)
    }

    /// Sign and submit an ordered wave of fully specified calls at
    /// consecutive nonces from the mined count at latest. Position is
    /// priority: nonce order means the head includes first or nothing
    /// does. Pool verdicts are per transaction and never abort the
    /// tail; the outer error covers only failing to observe the chain
    /// or to sign.
    pub async fn submit_wave(
        &self,
        wave: Vec<(String, TransactionRequest)>,
    ) -> Result<Vec<SendReport>> {
        for (label, request) in &wave {
            self.validate(label, request)?;
        }
        let base = self.mined_nonce_at_latest().await?;
        let fees = normalize_fees(
            self.read_provider
                .estimate_eip1559_fees()
                .await
                .context("failed to estimate fees for the wave")?,
        );

        let mut reports = Vec::with_capacity(wave.len());
        for (offset, (label, request)) in wave.into_iter().enumerate() {
            let nonce = base + offset as u64;
            let (raw, tx_hash) = self
                .sign(request, nonce, fees)
                .await
                .with_context(|| format!("failed to sign {label} transaction"))?;
            let verdict = match self.submit_provider.send_raw_transaction(&raw).await {
                Ok(_pending) => {
                    debug!(
                        "submitted {label} transaction {tx_hash} at nonce {nonce} \
                         with max fee {} and priority fee {}",
                        fees.max_fee_per_gas, fees.max_priority_fee_per_gas
                    );
                    SendVerdict::Submitted
                }
                Err(error) => match classify_submission_error(&error) {
                    SubmissionErrorKind::AlreadyKnown => {
                        trace!("{label} transaction {tx_hash} is already pending at nonce {nonce}");
                        SendVerdict::AlreadyKnown
                    }
                    SubmissionErrorKind::ReplacementUnderpriced => {
                        trace!(
                            "{label} at nonce {nonce} waits: the pending transaction \
                             is priced above the current quote"
                        );
                        SendVerdict::Underpriced
                    }
                    SubmissionErrorKind::NonceTooLow => {
                        trace!(
                            "{label} at nonce {nonce} is stale: inclusion advanced; \
                             the next tick replans"
                        );
                        SendVerdict::Stale
                    }
                    SubmissionErrorKind::Other => {
                        warn!(
                            "failed to submit {label} transaction {tx_hash} \
                             at nonce {nonce}: {error}"
                        );
                        SendVerdict::Failed
                    }
                },
            };
            reports.push(SendReport {
                label,
                nonce,
                tx_hash,
                verdict,
            });
        }
        Ok(reports)
    }

    fn validate(&self, label: &str, request: &TransactionRequest) -> Result<()> {
        ensure!(
            request.gas.is_some(),
            "{label} transaction has no explicit gas limit"
        );
        ensure!(
            request.nonce.is_none(),
            "{label} transaction must leave nonce ownership to the transaction lane"
        );
        ensure!(
            request.gas_price.is_none()
                && request.max_fee_per_gas.is_none()
                && request.max_priority_fee_per_gas.is_none(),
            "{label} transaction must leave fee ownership to the transaction lane"
        );
        if let Some(from) = request.from {
            ensure!(
                from == self.signer_address,
                "{label} transaction sender {from} is not lane signer {}",
                self.signer_address
            );
        }
        Ok(())
    }

    async fn mined_nonce_at_latest(&self) -> Result<u64> {
        self.read_provider
            .get_transaction_count(self.signer_address)
            .latest()
            .await
            .context("failed to read signer nonce at latest mined state")
    }

    async fn sign(
        &self,
        mut request: TransactionRequest,
        nonce: u64,
        fees: Eip1559Estimation,
    ) -> Result<(Vec<u8>, B256)> {
        request.set_from(self.signer_address);
        request.set_chain_id(self.chain_id);
        request.set_nonce(nonce);
        request.set_max_fee_per_gas(fees.max_fee_per_gas);
        request.set_max_priority_fee_per_gas(fees.max_priority_fee_per_gas);
        ensure!(
            request.can_build(),
            "transaction is not fully specified after lane preparation"
        );

        let envelope = request
            .build(&self.wallet)
            .await
            .context("wallet could not sign transaction")?;
        let raw = envelope.encoded_2718();
        let tx_hash = keccak256(&raw);
        Ok((raw, tx_hash))
    }
}

/// One wave slot's outcome: what was handed to the pool and what it
/// said.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SendReport {
    pub label: String,
    pub nonce: u64,
    pub tx_hash: B256,
    pub verdict: SendVerdict,
}

/// The pool's verdict on one send. Everything short of `Failed` is a
/// healthy lane: submitted and pending, an identical transaction
/// already pending, a higher-priced pending transaction worth waiting
/// out, or a plan built on an observation inclusion already advanced
/// past.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendVerdict {
    Submitted,
    AlreadyKnown,
    Underpriced,
    Stale,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SubmissionErrorKind {
    AlreadyKnown,
    NonceTooLow,
    ReplacementUnderpriced,
    Other,
}

fn normalize_fees(mut fees: Eip1559Estimation) -> Eip1559Estimation {
    fees.max_fee_per_gas = fees.max_fee_per_gas.max(fees.max_priority_fee_per_gas);
    fees
}

fn classify_submission_error(error: &TransportError) -> SubmissionErrorKind {
    let message = error
        .as_error_resp()
        .map(|payload| payload.message.as_ref())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let known_transaction = message
        .strip_prefix("known transaction")
        .is_some_and(|suffix| {
            suffix.is_empty() || suffix.starts_with(' ') || suffix.starts_with(':')
        });
    if message.contains("already known")
        || known_transaction
        || message.contains("already imported")
    {
        SubmissionErrorKind::AlreadyKnown
    } else if message.contains("nonce too low") || message.contains("nonce has already been used") {
        SubmissionErrorKind::NonceTooLow
    } else if message.contains("replacement transaction underpriced")
        || message.contains("replacement underpriced")
        || message.contains("fee too low to replace")
        || message.contains("transaction underpriced")
    {
        SubmissionErrorKind::ReplacementUnderpriced
    } else {
        SubmissionErrorKind::Other
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        network::TransactionBuilder,
        node_bindings::Anvil,
        providers::{ProviderBuilder, ext::AnvilApi},
        rpc::json_rpc::ErrorPayload,
        rpc::types::TransactionRequest,
        signers::Signer,
    };

    #[test]
    fn normalized_fees_never_price_priority_above_the_cap() {
        let skewed = Eip1559Estimation {
            max_fee_per_gas: 5,
            max_priority_fee_per_gas: 9,
        };
        assert_eq!(normalize_fees(skewed).max_fee_per_gas, 9);
    }

    #[test]
    fn submission_errors_have_explicit_nonce_lane_meanings() {
        fn error(message: &'static str) -> TransportError {
            TransportError::err_resp(ErrorPayload::internal_error_message(message.into()))
        }

        assert_eq!(
            classify_submission_error(&error("already known")),
            SubmissionErrorKind::AlreadyKnown
        );
        assert_eq!(
            classify_submission_error(&error("transaction already imported")),
            SubmissionErrorKind::AlreadyKnown
        );
        assert_eq!(
            classify_submission_error(&error("known transaction: 0x1234")),
            SubmissionErrorKind::AlreadyKnown
        );
        assert_eq!(
            classify_submission_error(&error("unknown transaction type 0x7e")),
            SubmissionErrorKind::Other
        );
        assert_eq!(
            classify_submission_error(&error("nonce too low")),
            SubmissionErrorKind::NonceTooLow
        );
        assert_eq!(
            classify_submission_error(&error("replacement transaction underpriced")),
            SubmissionErrorKind::ReplacementUnderpriced
        );
    }

    fn payment(to_byte: u8) -> TransactionRequest {
        TransactionRequest::default()
            .with_to(Address::repeat_byte(to_byte))
            .with_gas_limit(21_000)
    }

    fn wave(entries: &[(&str, u8)]) -> Vec<(String, TransactionRequest)> {
        entries
            .iter()
            .map(|(label, to_byte)| (label.to_string(), payment(*to_byte)))
            .collect()
    }

    async fn spawn_lane() -> Result<(
        alloy::node_bindings::AnvilInstance,
        DynProvider,
        TransactionLane,
        Address,
    )> {
        let anvil = Anvil::new().spawn();
        let read_provider = ProviderBuilder::new()
            .disable_recommended_fillers()
            .connect_http(anvil.endpoint_url())
            .erased();
        let submit_provider = ProviderBuilder::new()
            .disable_recommended_fillers()
            .connect_http(anvil.endpoint_url())
            .erased();
        read_provider.anvil_set_auto_mine(false).await?;

        let mut signer: PrivateKeySigner = anvil.keys()[0].clone().into();
        signer.set_chain_id(Some(anvil.chain_id()));
        let signer_address = signer.address();
        let lane = TransactionLane::new(
            read_provider.clone(),
            submit_provider,
            anvil.chain_id(),
            EthereumWallet::from(signer),
        );
        Ok((anvil, read_provider, lane, signer_address))
    }

    async fn nonces(provider: &DynProvider, signer: Address) -> Result<(u64, u64)> {
        let latest = provider.get_transaction_count(signer).latest().await?;
        let pending = provider.get_transaction_count(signer).pending().await?;
        Ok((latest, pending))
    }

    fn verdicts(reports: &[SendReport]) -> Vec<(u64, SendVerdict)> {
        reports
            .iter()
            .map(|report| (report.nonce, report.verdict))
            .collect()
    }

    /// The lane's whole observable contract on a public pool: waves
    /// take consecutive nonces from the mined count, identical
    /// rebuilds deduplicate in the pool, a changed intent at an
    /// unmoved quote waits behind the pending transaction instead of
    /// force-evicting it, inclusion shifts the base, and a rolled-back
    /// nonce is reusable with no lane-side reconciliation - there is
    /// no lane state to reconcile.
    #[tokio::test]
    async fn stateless_wave_defers_to_the_pool() -> Result<()> {
        let (_anvil, provider, lane, signer) = spawn_lane().await?;
        let before_submissions = provider.anvil_snapshot().await?;

        let first = lane
            .submit_wave(wave(&[("first", 0x11), ("second", 0x22)]))
            .await?;
        assert_eq!(
            verdicts(&first),
            vec![(0, SendVerdict::Submitted), (1, SendVerdict::Submitted)]
        );
        assert_eq!(nonces(&provider, signer).await?, (0, 2));

        // The same wave rebuilt: same quote, same bytes, pool dedup.
        let rebuilt = lane
            .submit_wave(wave(&[("first", 0x11), ("second", 0x22)]))
            .await?;
        assert_eq!(
            verdicts(&rebuilt),
            vec![
                (0, SendVerdict::AlreadyKnown),
                (1, SendVerdict::AlreadyKnown)
            ]
        );
        assert_eq!(rebuilt[0].tx_hash, first[0].tx_hash);
        assert_eq!(nonces(&provider, signer).await?, (0, 2));

        // A changed head at an unmoved quote cannot outbid the pending
        // transaction; it waits, and the pending set is untouched.
        let changed = lane
            .submit_wave(wave(&[("changed", 0x33), ("second", 0x22)]))
            .await?;
        assert_eq!(
            verdicts(&changed),
            vec![
                (0, SendVerdict::Underpriced),
                (1, SendVerdict::AlreadyKnown)
            ]
        );
        assert_eq!(nonces(&provider, signer).await?, (0, 2));

        // Inclusion is prefix shaped and shifts the next wave up.
        provider.anvil_mine(Some(1), None).await?;
        assert_eq!(nonces(&provider, signer).await?, (2, 2));
        let next = lane.submit_wave(wave(&[("next", 0x44)])).await?;
        assert_eq!(verdicts(&next), vec![(2, SendVerdict::Submitted)]);

        // A reorg rolls the base back; the stateless lane just reads
        // the rolled-back count and reuses the nonce.
        assert!(provider.anvil_revert(before_submissions).await?);
        let after_reorg = lane.submit("after-reorg", payment(0x55)).await?;
        assert_eq!(after_reorg.nonce, 0);
        assert_eq!(after_reorg.verdict, SendVerdict::Submitted);

        Ok(())
    }

    /// A process restart is invisible to the pool: there is no lane
    /// state to lose, so resubmission deduplicates and a changed
    /// intent waits exactly as it would have without the restart.
    #[tokio::test]
    async fn restart_is_invisible_to_the_pool() -> Result<()> {
        let (anvil, provider, lane, signer) = spawn_lane().await?;

        let original = lane.submit("before-restart", payment(0x11)).await?;
        assert_eq!(original.verdict, SendVerdict::Submitted);
        drop(lane);

        let mut signer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
        signer_key.set_chain_id(Some(anvil.chain_id()));
        let restarted = TransactionLane::new(
            provider.clone(),
            provider.clone(),
            anvil.chain_id(),
            EthereumWallet::from(signer_key),
        );

        let resubmitted = restarted.submit("same-intent", payment(0x11)).await?;
        assert_eq!(resubmitted.verdict, SendVerdict::AlreadyKnown);
        assert_eq!(resubmitted.tx_hash, original.tx_hash);

        let changed = restarted.submit("changed-intent", payment(0x22)).await?;
        assert_eq!(changed.verdict, SendVerdict::Underpriced);
        assert_eq!(
            nonces(&provider, signer).await?,
            (0, 1),
            "the changed intent must wait, not evict or queue"
        );

        Ok(())
    }
}
