// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::args::SignerArgs;
use crate::kms::{CommonSignature, KmsSignerBuilder};
use alloy::{
    eips::{eip1559::Eip1559Estimation, eip2718::Encodable2718},
    network::{
        Ethereum, EthereumWallet, NetworkTransactionBuilder, NetworkWallet, TransactionBuilder,
    },
    primitives::{Address, B256, U256, keccak256, utils::format_ether},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::{
        client::RpcClient,
        json_rpc::{RequestPacket, ResponsePacket},
        types::TransactionRequest,
    },
    signers::local::PrivateKeySigner,
    transports::http::{Http, reqwest::Url},
};
use alloy_chains::NamedChain;
use alloy_transport::{
    HttpError, RpcError, TransportError, TransportErrorKind, TransportFut,
    layers::{RateLimitRetryPolicy, RetryBackoffLayer, RetryPolicy},
};
use anyhow::{Context, Result, anyhow, ensure};
use log::{debug, error, info, trace, warn};
use std::{
    fs,
    str::FromStr,
    task::{Context as TaskContext, Poll},
    time::Duration,
};

/// Errors name the flag and add no key material: a key parse error may
/// quote the key's characters, so it is dropped.
pub(crate) async fn create_signer(
    chain_id: NamedChain,
    signer_args: &SignerArgs,
) -> Result<(Address, EthereumWallet)> {
    let signer: Box<CommonSignature> = match signer_args {
        SignerArgs::Pk {
            web3_private_key,
            web3_private_key_file,
        } => {
            let pk = if let Some(file) = web3_private_key_file {
                fs::read_to_string(file)
                    .with_context(|| {
                        format!(
                            "failed to read --web3-private-key-file `{}`",
                            file.display()
                        )
                    })?
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string()
            } else {
                web3_private_key.clone().unwrap()
            };

            let local_signer = PrivateKeySigner::from_str(&pk).map_err(|_| {
                anyhow!("--web3-private-key(-file) does not hold a valid private key")
            })?;

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
                    .with_context(|| {
                        format!("failed to read --aws-kms-key-id-file `{}`", file.display())
                    })?
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
                .context(
                    "failed to create the AWS KMS signer (--aws-kms-key-id(-file), \
                     --aws-endpoint-url, --aws-region)",
                )?;

            Box::new(kms_signer)
        }
    };

    let wallet = EthereumWallet::from(signer);
    let wallet_address =
        <EthereumWallet as NetworkWallet<Ethereum>>::default_signer_address(&wallet);

    Ok((wallet_address, wallet))
}

/// reqwest's defaults, except where noted: HTTP/2 where TLS negotiates it
/// (every hosted provider), HTTP/1.1 on plain http, and TCP keepalive.
fn create_client(url: &Url) -> Result<RpcClient> {
    let client = reqwest::Client::builder()
        // A request timeout does not evict a shared HTTP/2 connection; an
        // unanswered PING does. Its timeout sits below the request timeout,
        // so a dead connection fails, and leaves the pool, before the
        // caller's next request.
        .http2_keep_alive_interval(Duration::from_secs(30))
        .http2_keep_alive_timeout(Duration::from_secs(10))
        // Below the idle closes of nginx (75 s) and geth (120 s), so an
        // HTTP/1.1 connection is not reused just as the server drops it.
        .pool_idle_timeout(Duration::from_secs(60))
        // Per attempt, connect through body. alloy never resends a timeout,
        // and logs_bisecting splits on it.
        .timeout(Duration::from_secs(20))
        .build()
        .context(
            "failed to build the HTTP client (on Linux it needs the system's CA certificates)",
        )?;
    let transport = Http::with_client(client, url.clone());
    let is_local = transport.guess_local();

    Ok(RpcClient::builder()
        .layer(retry_layer())
        .layer(RedactUrlLayer(url.to_string()))
        .transport(transport, is_local))
}

/// Two resends, one second apart, of what [`RateLimitOnly`] lets through:
/// enough to clear a per-second cap that rejects part of a tick's
/// concurrent reads. A longer limit is the next tick's to wait out.
fn retry_layer() -> RetryBackoffLayer<RateLimitOnly> {
    // A fixed backoff, not an exponential base. u64::MAX turns off alloy's
    // compute-unit queueing, which models a provider's plan the node does
    // not know.
    RetryBackoffLayer::new_with_policy(2, 1_000, u64::MAX, RateLimitOnly::default())
}

/// The longest server-requested wait a resend honors within a tick.
const MAX_RETRY_WAIT: Duration = Duration::from_secs(5);

/// alloy's rate-limit policy minus two resends that cannot help within a
/// tick: Infura's result-count rejection, which reuses its rate-limit code
/// (-32005) but clears only by narrowing the range (logs_bisecting), and a
/// server asking to wait longer than [`MAX_RETRY_WAIT`]. That wait is the
/// hint the layer sleeps on, so no resend waits longer. alloy drops a
/// Retry-After header that comes with a JSON-RPC error body, and resends
/// that 429 at the one-second backoff. Should Infura reword the rejection,
/// it is resent as before: wasteful, never stuck.
#[derive(Clone, Copy, Debug, Default)]
struct RateLimitOnly(RateLimitRetryPolicy);

impl RetryPolicy for RateLimitOnly {
    fn should_retry(&self, error: &TransportError) -> bool {
        let size_rejection = error.as_error_resp().is_some_and(|payload| {
            payload.code == -32005 && payload.message.contains("query returned more than")
        });
        let long_wait = self
            .0
            .backoff_hint(error)
            .is_some_and(|wait| wait > MAX_RETRY_WAIT);
        !size_rejection && !long_wait && self.0.should_retry(error)
    }

    fn backoff_hint(&self, error: &TransportError) -> Option<Duration> {
        self.0.backoff_hint(error)
    }
}

/// Strips the endpoint's URL, which often carries an API key, from
/// transport errors before any caller logs them: reqwest quotes the URL in
/// its connection, timeout and body errors, and alloy copies a body error's
/// text into an HTTP error. The error kind is kept, so retry decisions see
/// the same error.
#[derive(Clone, Debug)]
struct RedactUrlLayer(String);

impl<S> tower::Layer<S> for RedactUrlLayer {
    type Service = RedactUrl<S>;

    fn layer(&self, inner: S) -> Self::Service {
        RedactUrl {
            inner,
            url: self.0.clone(),
        }
    }
}

#[derive(Clone, Debug)]
struct RedactUrl<S> {
    inner: S,
    url: String,
}

impl<S> tower::Service<RequestPacket> for RedactUrl<S>
where
    S: tower::Service<
            RequestPacket,
            Response = ResponsePacket,
            Error = TransportError,
            Future = TransportFut<'static>,
        >,
{
    type Response = ResponsePacket;
    type Error = TransportError;
    type Future = TransportFut<'static>;

    fn poll_ready(&mut self, context: &mut TaskContext<'_>) -> Poll<Result<(), TransportError>> {
        let url = &self.url;
        self.inner
            .poll_ready(context)
            .map_err(|error| redact_url(error, url))
    }

    fn call(&mut self, request: RequestPacket) -> Self::Future {
        let response = self.inner.call(request);
        let url = self.url.clone();
        Box::pin(async move { response.await.map_err(|error| redact_url(error, &url)) })
    }
}

fn redact_url(error: TransportError, url: &str) -> TransportError {
    let scrub = |text: &str| text.replace(url, "<rpc url>");
    match error {
        RpcError::Transport(TransportErrorKind::Custom(inner)) => {
            match inner.downcast::<reqwest::Error>() {
                Ok(error) => TransportErrorKind::custom(error.without_url()),
                Err(inner) => RpcError::Transport(TransportErrorKind::Custom(inner)),
            }
        }
        RpcError::Transport(TransportErrorKind::HttpError(HttpError { status, body })) => {
            TransportErrorKind::http_error(status, scrub(&body))
        }
        RpcError::Transport(TransportErrorKind::HttpErrorWithRetryAfter {
            error: HttpError { status, body },
            retry_after,
        }) => {
            TransportErrorKind::http_error_with_retry_after(status, scrub(&body), Some(retry_after))
        }
        other => other,
    }
}

/// Build a signerless provider. Transaction filling is intentionally disabled:
/// every node mutation is fully specified and signed by [`TransactionLane`].
/// Callers name the endpoint's flag; no error, here or from any later
/// request, quotes the URL, which may carry an API key.
pub async fn create_rpc_provider(url: &Url, arg_chain_id: NamedChain) -> Result<DynProvider> {
    let client = create_client(url)?;
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .with_chain(arg_chain_id)
        .connect_client(client);

    let chain_id = provider
        .get_chain_id()
        .await
        .context("failed to query the endpoint's chain id")?;
    ensure!(
        chain_id == arg_chain_id as u64,
        "the endpoint serves chain {chain_id}, not --web3-chain-id {}",
        arg_chain_id as u64
    );

    Ok(provider.erased())
}

/// A labeled request bound for the lane; the label names the on-chain verb
/// for logs and reports. The lane fills nonce, fees and, unless the request
/// pins one, the gas limit.
pub type LaneRequest = (String, TransactionRequest);

/// Gas limit when estimation fails for a reason other than a revert. It
/// covers every action's measured cost (the largest, a maximum-input leaf
/// proof, is about 5.1M) and stays below the EIP-7825 transaction cap.
const FALLBACK_GAS_LIMIT: u64 = 15_000_000;

/// EIP-7825's per-transaction gas cap: a pool on a chain past Osaka admits
/// nothing above it.
const TX_GAS_CAP: u64 = 1 << 24;
const _: () = assert!(FALLBACK_GAS_LIMIT <= TX_GAS_CAP);

/// The least headroom over an estimate. It covers the pairing branch, the
/// largest state move between an estimate and inclusion: a join or one of
/// the three win paths that finds a rival's commitment dangling by
/// inclusion stores a match and starts its clocks. The harness measured
/// that move at 117,262 gas on every level's first match, 70% of the
/// cheapest join's estimate, so half the estimate alone runs a join out of
/// gas; this adds a quarter as margin.
const MIN_HEADROOM: u64 = 150_000;

/// The gas limit for an estimate at latest: half the estimate again, at
/// least [`MIN_HEADROOM`], for drift before inclusion (cold slots, a refund
/// that was zero, the pairing branch). Unused gas is not charged, but a
/// pool reserves the whole limit at the max fee against the balance.
///
/// The limit stops at the EIP-7825 cap, which never lowers it below its
/// estimate. An estimate above the cap keeps its headroom: no EIP-7825
/// chain admits it anyway, and a chain without the cap needs it.
pub(crate) fn gas_limit_for(estimate: u64) -> u64 {
    let padded = estimate.saturating_add((estimate / 2).max(MIN_HEADROOM));
    if estimate <= TX_GAS_CAP {
        padded.min(TX_GAS_CAP)
    } else {
        padded
    }
}

/// The node signer's stateless transaction lane.
///
/// Nonces come from the account's mined count at the `latest` block,
/// fees are the fresh market quote at every submission, gas limits come
/// from an estimate at `latest`, and the mempool (or block builder) stays
/// the sole authority on duplicates and replacements: "already known" and
/// "replacement underpriced" are benign verdicts, and a stale nonce means
/// inclusion advanced past the plan and the next tick replans. A slot
/// turned down on price is signed once more with its tip raised to the
/// quote's max fee ([`replacement_fees`]), which displaces any pending
/// transaction the base fee has outrun. The lane holds no mutable state -
/// callers re-derive and resubmit their complete intent every tick, so
/// anything a lost response could forget is rebuilt from observation.
///
/// Submissions flow from the epoch manager's serial loop. Mutable
/// access makes that single-owner constraint explicit: two waves
/// cannot race nonces through the same lane.
#[derive(Debug)]
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
    /// stay benign, as in a wave. Production submits whole waves.
    #[cfg(test)]
    pub async fn submit(&mut self, label: &str, request: TransactionRequest) -> Result<SendReport> {
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

    /// Sign and submit an ordered wave of calls at consecutive nonces
    /// from the mined count at latest. Position is priority: nonce order
    /// means the head includes first or nothing does. A call that reverts
    /// at latest is not sent and takes no nonce. Pool verdicts are per
    /// transaction and never abort the tail; the outer error covers only
    /// failing to observe the chain or to sign.
    pub async fn submit_wave(&mut self, wave: Vec<LaneRequest>) -> Result<Vec<SendReport>> {
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
        let mut nonce = base;
        let mut reserved = U256::ZERO;
        for (label, mut request) in wave {
            if request.gas.is_none() {
                let Some(gas) = self.gas_limit(&label, &request).await else {
                    reports.push(SendReport {
                        label,
                        nonce,
                        tx_hash: B256::ZERO,
                        verdict: SendVerdict::Reverts,
                    });
                    continue;
                };
                request.set_gas_limit(gas);
            }
            let cost = reserve(
                request.gas.unwrap_or_default(),
                fees.max_fee_per_gas,
                request.value.unwrap_or_default(),
            );
            let (raw, tx_hash) = self
                .sign(request.clone(), nonce, fees)
                .await
                .with_context(|| format!("failed to sign {label} transaction"))?;
            let sent = self.submit_provider.send_raw_transaction(&raw).await;
            let (tx_hash, verdict) = match sent {
                Err(error)
                    if replacement_fees(fees) != fees
                        && matches!(
                            classify_submission_error(&error),
                            SubmissionErrorKind::ReplacementUnderpriced
                                | SubmissionErrorKind::Underpriced
                        ) =>
                {
                    self.outbid(&label, request, nonce, fees, (tx_hash, error))
                        .await
                }
                sent => (tx_hash, judge(&label, nonce, tx_hash, fees, sent.map(drop))),
            };
            // A stale slot's nonce already mined; nothing pools for it.
            if verdict != SendVerdict::Stale {
                reserved = reserved.saturating_add(cost);
            }
            reports.push(SendReport {
                label,
                nonce,
                tx_hash,
                verdict,
            });
            nonce += 1;
        }
        self.check_funding(reserved).await;
        Ok(reports)
    }

    /// Advisory, and after the sends: holding a dispute step is the stall,
    /// and the pool decides admission anyway. It speaks on the first tick a
    /// batch exists, when a private relay would accept an unaffordable batch
    /// silently. The reserve is a lower bound: transactions an earlier,
    /// longer batch left pooled above these nonces count against the
    /// balance too.
    async fn check_funding(&self, reserved: U256) {
        if reserved.is_zero() {
            return;
        }
        match self
            .read_provider
            .get_balance(self.signer_address)
            .latest()
            .await
        {
            Ok(balance) if balance < reserved => error!(
                "signer {} holds {} ETH but this batch reserves {} ETH, {} ETH short: \
                 a pool admits the batch only while the balance covers every gas limit \
                 at its max fee plus its value; fund it before a dispute clock runs out",
                self.signer_address,
                format_ether(balance),
                format_ether(reserved),
                format_ether(reserved - balance)
            ),
            Ok(_) => {}
            Err(error) => warn!("failed to read the signer's balance to check the batch: {error}"),
        }
    }

    /// The padded estimate at latest ([`gas_limit_for`]), or `None` when
    /// the call reverts there. Any other estimation failure falls back to
    /// the flat limit: a flaky endpoint must not hold back a dispute action,
    /// and a real problem such as an underfunded signer still fails loudly
    /// at submission.
    async fn gas_limit(&self, label: &str, request: &TransactionRequest) -> Option<u64> {
        let mut probe = request.clone();
        probe.set_from(self.signer_address);
        match self.read_provider.estimate_gas(probe).latest().await {
            Ok(estimate) => Some(gas_limit_for(estimate)),
            Err(error) if is_revert(&error) => {
                warn!("{label} is not sent: it reverts at latest: {error}");
                None
            }
            Err(error) => {
                warn!("{label} gas estimation failed, using {FALLBACK_GAS_LIMIT}: {error}");
                Some(FALLBACK_GAS_LIMIT)
            }
        }
    }

    /// The one retry of a slot the pool turned down on price, at the
    /// quote's max fee with the tip raised to it ([`replacement_fees`]).
    /// Its verdict and hash replace the first attempt's; a retry that
    /// cannot be signed keeps them.
    async fn outbid(
        &self,
        label: &str,
        request: TransactionRequest,
        nonce: u64,
        quote: Eip1559Estimation,
        (first_hash, first_error): (B256, TransportError),
    ) -> (B256, SendVerdict) {
        let fees = replacement_fees(quote);
        let (raw, tx_hash) = match self.sign(request, nonce, fees).await {
            Ok(signed) => signed,
            Err(error) => {
                warn!(
                    "{label} at nonce {nonce}: its retry at the max tip cannot be signed: {error:#}"
                );
                let verdict = judge(label, nonce, first_hash, quote, Err(first_error));
                return (first_hash, verdict);
            }
        };
        let sent = self.submit_provider.send_raw_transaction(&raw).await;
        if sent.is_ok() {
            let quoted = format!(
                "quoted max fee {} and priority fee {}",
                quote.max_fee_per_gas, quote.max_priority_fee_per_gas
            );
            if classify_submission_error(&first_error) == SubmissionErrorKind::Underpriced {
                // Visible on purpose: a full pool or a minimum tip above the
                // quote costs the max fee on every send.
                warn!(
                    "{label} at nonce {nonce} was turned down at the quote ({first_error}) \
                     and sent with its priority fee raised to the max fee ({quoted})"
                );
            } else {
                info!(
                    "{label} at nonce {nonce} replaces a pending transaction the quote \
                     could not: priority fee raised to the max fee {} ({quoted})",
                    fees.max_fee_per_gas
                );
            }
        }
        (tx_hash, judge(label, nonce, tx_hash, fees, sent.map(drop)))
    }

    fn validate(&self, label: &str, request: &TransactionRequest) -> Result<()> {
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
/// already pending, a pending transaction that outbids even the max-tip
/// retry and so is includable at the current base fee, or a plan built
/// on an observation inclusion already advanced past.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendVerdict {
    Submitted,
    AlreadyKnown,
    Underpriced,
    Stale,
    /// Not sent: the call reverts at latest. The report has a zero hash,
    /// and its nonce went to the next request.
    Reverts,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SubmissionErrorKind {
    AlreadyKnown,
    NonceTooLow,
    ReplacementUnderpriced,
    /// Turned down on price, not as a replacement: a full pool (geth's
    /// bare "transaction underpriced") or a minimum tip (the same words on
    /// geth 1.13 and erigon). It takes the max-tip retry, then fails.
    Underpriced,
    Other,
}

/// The pool's answer to one send, logged at the level it deserves.
fn judge(
    label: &str,
    nonce: u64,
    tx_hash: B256,
    fees: Eip1559Estimation,
    sent: Result<(), TransportError>,
) -> SendVerdict {
    let error = match sent {
        Ok(()) => {
            debug!(
                "submitted {label} transaction {tx_hash} at nonce {nonce} \
                 with max fee {} and priority fee {}",
                fees.max_fee_per_gas, fees.max_priority_fee_per_gas
            );
            return SendVerdict::Submitted;
        }
        Err(error) => error,
    };
    match classify_submission_error(&error) {
        SubmissionErrorKind::AlreadyKnown => {
            trace!("{label} transaction {tx_hash} is already pending at nonce {nonce}");
            SendVerdict::AlreadyKnown
        }
        SubmissionErrorKind::ReplacementUnderpriced => {
            trace!(
                "{label} at nonce {nonce} waits: the pending transaction \
                 outbids the quote's max fee, so it is includable"
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
        SubmissionErrorKind::Underpriced | SubmissionErrorKind::Other => {
            // Loud on purpose: a persistent rejection here (an underfunded
            // signer, or a full pool or minimum tip that outbids even the
            // max-tip retry) stalls the whole nonce tail while dispute
            // clocks run.
            error!("failed to submit {label} transaction {tx_hash} at nonce {nonce}: {error}");
            SendVerdict::Failed
        }
    }
}

/// What a pool holds against the balance for one transaction: its whole
/// gas limit at its max fee, plus its value.
fn reserve(gas_limit: u64, max_fee_per_gas: u128, value: U256) -> U256 {
    (U256::from(gas_limit) * U256::from(max_fee_per_gas)).saturating_add(value)
}

/// The fees of the one retry a slot turned down on price gets: the quote's
/// max fee, with the tip raised to it. geth replaces a pending transaction
/// only on 10% more of both fees. One the base fee has outrun has both
/// below the next base fee, at most 1.125 times the latest, while the
/// quote's max fee is twice the latest, so the retry displaces it. A
/// pending transaction that survives the retry has a fee cap above
/// 1.8 times the latest base fee, so it is includable and is waited out.
fn replacement_fees(quote: Eip1559Estimation) -> Eip1559Estimation {
    Eip1559Estimation {
        max_fee_per_gas: quote.max_fee_per_gas,
        max_priority_fee_per_gas: quote.max_fee_per_gas,
    }
}

fn normalize_fees(mut fees: Eip1559Estimation) -> Eip1559Estimation {
    fees.max_fee_per_gas = fees.max_fee_per_gas.max(fees.max_priority_fee_per_gas);
    fees
}

// The pool and revert wordings below are checked against geth and anvil;
// erigon's and other clients' are a lead. An unmatched replacement
// rejection logs an error and skips the max-tip retry; an unmatched revert
// falls back to the flat gas limit and pays the revert on chain. Neither
// stalls the lane.
fn is_revert(error: &TransportError) -> bool {
    error
        .as_error_resp()
        .is_some_and(|payload| payload.message.to_ascii_lowercase().contains("revert"))
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
    {
        SubmissionErrorKind::ReplacementUnderpriced
    } else if message.contains("transaction underpriced") {
        SubmissionErrorKind::Underpriced
    } else {
        SubmissionErrorKind::Other
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        consensus::Transaction,
        network::TransactionBuilder,
        node_bindings::Anvil,
        primitives::{Bytes, U64},
        providers::{ProviderBuilder, ext::AnvilApi, utils::eip1559_default_estimator},
        rpc::json_rpc::ErrorPayload,
        rpc::types::{Block, FeeHistory, TransactionRequest},
        signers::Signer,
        transports::mock::Asserter,
    };

    fn error_response(code: i64, message: &'static str) -> TransportError {
        RpcError::ErrorResp(ErrorPayload {
            code,
            message: message.into(),
            data: None,
        })
    }

    #[test]
    fn the_retry_policy_resends_rate_limits_only_within_the_tick() {
        let policy = RateLimitOnly::default();
        for retried in [
            error_response(429, "Too Many Requests"),
            error_response(-32005, "Rate limit exceeded"),
            error_response(-32005, "project ID request rate exceeded"),
            TransportErrorKind::http_error_with_retry_after(
                429,
                "Too Many Requests".into(),
                Some(Duration::from_secs(2)),
            ),
        ] {
            assert!(policy.should_retry(&retried), "{retried}");
        }
        let backoff = serde_json::value::to_raw_value(
            &serde_json::json!({ "rate": { "backoff_seconds": 30 } }),
        )
        .unwrap();
        for sent_once in [
            // Infura's result-count rejection clears only by splitting.
            error_response(
                -32005,
                "query returned more than 10000 results. Try with this block range [0x15ef3c0, 0x15ef4ff].",
            ),
            // A longer wait is the next tick's.
            TransportErrorKind::http_error_with_retry_after(
                429,
                "Too Many Requests".into(),
                Some(Duration::from_secs(30)),
            ),
            RpcError::ErrorResp(ErrorPayload {
                code: -32005,
                message: "project ID request rate exceeded".into(),
                data: Some(backoff),
            }),
            // A hang or a dead endpoint is never resent.
            TransportErrorKind::custom_str("operation timed out"),
        ] {
            assert!(!policy.should_retry(&sent_once), "{sent_once}");
        }
    }

    #[tokio::test]
    async fn a_rate_limit_is_sent_three_times() {
        let asserter = Asserter::new();
        for _ in 0..3 {
            asserter.push_failure(ErrorPayload {
                code: 429,
                message: "Too Many Requests".into(),
                data: None,
            });
        }
        let client = RpcClient::builder().layer(retry_layer()).transport(
            alloy::transports::mock::MockTransport::new(asserter.clone()),
            true,
        );

        let error = client
            .request_noparams::<U64>("eth_blockNumber")
            .await
            .unwrap_err();
        assert!(
            error.to_string().contains("Max retries exceeded"),
            "{error}"
        );
        assert!(asserter.read_q().is_empty());
    }

    /// A provider URL often carries an API key; no request error may quote
    /// it, while the error still says what failed.
    #[tokio::test]
    async fn request_errors_do_not_quote_the_rpc_url() {
        let url: Url = "http://127.0.0.1:1/v2/not-a-real-api-key".parse().unwrap();
        let client = create_client(&url).unwrap();
        let error = client
            .request_noparams::<U64>("eth_blockNumber")
            .await
            .unwrap_err();

        for rendered in [format!("{error:#}"), format!("{error:?}")] {
            assert!(!rendered.contains("not-a-real-api-key"), "{rendered}");
        }
        assert!(
            error.to_string().contains("error sending request"),
            "{error}"
        );
    }

    #[test]
    fn http_error_bodies_lose_the_rpc_url() {
        let url = "https://rpc.example/v2/not-a-real-api-key";
        let body =
            format!("<failed to read response body: error decoding response body for url ({url})>");

        let error = redact_url(TransportErrorKind::http_error(502, body.clone()), url);
        assert_eq!(
            error.to_string(),
            "HTTP error 502 with body: <failed to read response body: error decoding \
             response body for url (<rpc url>)>"
        );

        let delay = Duration::from_secs(3);
        match redact_url(
            TransportErrorKind::http_error_with_retry_after(429, body, Some(delay)),
            url,
        ) {
            RpcError::Transport(TransportErrorKind::HttpErrorWithRetryAfter {
                error,
                retry_after,
            }) => {
                assert_eq!(error.status, 429);
                assert!(!error.body.contains("not-a-real-api-key"));
                assert_eq!(retry_after, delay);
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn normalized_fees_never_price_priority_above_the_cap() {
        let skewed = Eip1559Estimation {
            max_fee_per_gas: 5,
            max_priority_fee_per_gas: 9,
        };
        assert_eq!(normalize_fees(skewed).max_fee_per_gas, 9);
    }

    #[test]
    fn gas_headroom_never_lifts_an_admissible_estimate_past_the_cap() {
        assert_eq!(gas_limit_for(21_000), 21_000 + MIN_HEADROOM);
        // Half the estimate takes over from the floor.
        assert_eq!(gas_limit_for(300_000), 450_000);
        assert_eq!(gas_limit_for(400_000), 600_000);
        // The maximum-input leaf proof of the 2026-10-02 calibration.
        assert_eq!(gas_limit_for(5_079_603), 7_619_404);
        assert_eq!(gas_limit_for(12_000_000), TX_GAS_CAP);
        assert_eq!(gas_limit_for(TX_GAS_CAP), TX_GAS_CAP);
        // Above the cap nothing is admitted on an EIP-7825 chain; a chain
        // without the cap keeps the headroom.
        assert_eq!(gas_limit_for(20_000_000), 30_000_000);
        assert_eq!(gas_limit_for(u64::MAX), u64::MAX);
    }

    #[test]
    fn a_batch_reserves_each_gas_limit_at_its_max_fee_plus_value() {
        assert_eq!(reserve(100, 3, U256::from(7)), U256::from(307));
        assert_eq!(reserve(u64::MAX, u128::MAX, U256::MAX), U256::MAX);
    }

    /// geth's replacement rule (legacypool list.go): both fees strictly
    /// higher and at least 10% higher.
    fn replaces(new: Eip1559Estimation, old: Eip1559Estimation) -> bool {
        let bumped = |new: u128, old: u128| new > old && new * 100 >= old * 110;
        bumped(new.max_fee_per_gas, old.max_fee_per_gas)
            && bumped(new.max_priority_fee_per_gas, old.max_priority_fee_per_gas)
    }

    #[test]
    fn a_max_tip_retry_displaces_what_the_base_fee_outran() {
        const GWEI: u128 = 1_000_000_000;
        for base in [7, GWEI, 100 * GWEI] {
            for tip in [1, 2 * GWEI] {
                let quote = eip1559_default_estimator(base, &[vec![tip]]);
                let retry = replacement_fees(quote);
                // The next block's base fee is at most 1.125 times the latest.
                let next_base = base * 9 / 8;
                let both = |fee| Eip1559Estimation {
                    max_fee_per_gas: fee,
                    max_priority_fee_per_gas: fee,
                };

                // Outrun, with the tip at its cap: the retry replaces it.
                let outrun = both(next_base - 1);
                assert!(replaces(retry, outrun));

                // Signed at the full quote, a pending transaction survives
                // the retry, and so does every cap from the boundary up;
                // all of them are includable.
                assert!(!replaces(retry, quote));
                let boundary = retry.max_fee_per_gas * 100 / 110;
                assert!(replaces(retry, both(boundary)));
                assert!(!replaces(retry, both(boundary + 1)));
                assert!(boundary + 1 >= next_base);
            }
        }
        // At a flat market tip the quote alone cannot replace it.
        let quote = eip1559_default_estimator(100 * GWEI, &[vec![2 * GWEI]]);
        assert!(!replaces(
            quote,
            Eip1559Estimation {
                max_fee_per_gas: 112 * GWEI,
                max_priority_fee_per_gas: 112 * GWEI,
            }
        ));
        // A quote whose tip is its max fee has no retry to offer.
        let flat = Eip1559Estimation {
            max_fee_per_gas: 5,
            max_priority_fee_per_gas: 5,
        };
        assert_eq!(replacement_fees(flat), flat);
    }

    /// A lane over mocked endpoints, each answering in call order: `reads`
    /// the nonce, the fee history (then the latest block when the history
    /// has no base fee) and, after the sends, the balance; `sends` each raw
    /// submission.
    fn mocked_lane() -> (TransactionLane, Asserter, Asserter) {
        let (reads, sends) = (Asserter::new(), Asserter::new());
        let provider = |asserter: &Asserter| {
            ProviderBuilder::new()
                .disable_recommended_fillers()
                .connect_mocked_client(asserter.clone())
                .erased()
        };
        let lane = TransactionLane::new(
            provider(&reads),
            provider(&sends),
            1,
            EthereumWallet::from(PrivateKeySigner::random()),
        );
        (lane, reads, sends)
    }

    fn fee_history(base: u128, tip: u128) -> FeeHistory {
        FeeHistory {
            base_fee_per_gas: vec![base, base],
            gas_used_ratio: vec![0.5],
            reward: Some(vec![vec![tip]]),
            oldest_block: 1,
            ..Default::default()
        }
    }

    /// An underpriced slot is signed once more at the max tip, and the
    /// report carries the retry's verdict and hash. Anvil replaces on a
    /// higher max fee alone, so only mocked endpoints reach this branch.
    /// The funding check after the sends never holds the reports back,
    /// whether the balance is short, ample or unreadable.
    #[tokio::test]
    async fn an_underpriced_slot_is_retried_once_at_the_max_tip() -> Result<()> {
        const GWEI: u128 = 1_000_000_000;
        let quote = eip1559_default_estimator(10 * GWEI, &[vec![GWEI]]);
        let replacement = "replacement transaction underpriced";
        let cases = [
            (replacement, None, SendVerdict::Submitted),
            (replacement, Some(replacement), SendVerdict::Underpriced),
            (
                replacement,
                Some("already known"),
                SendVerdict::AlreadyKnown,
            ),
            ("transaction underpriced", None, SendVerdict::Submitted),
            (
                "transaction underpriced",
                Some("transaction underpriced"),
                SendVerdict::Failed,
            ),
        ];
        for (case, (first, retry, verdict)) in cases.into_iter().enumerate() {
            let (mut lane, reads, sends) = mocked_lane();
            reads.push_success(&U64::from(7));
            reads.push_success(&fee_history(10 * GWEI, GWEI));
            match case % 3 {
                0 => reads.push_success(&U256::ZERO),
                1 => reads.push_failure_msg("balance unavailable"),
                _ => reads.push_success(&U256::MAX),
            }
            sends.push_failure_msg(first);
            match retry {
                None => sends.push_success(&B256::ZERO),
                Some(message) => sends.push_failure_msg(message),
            }
            let report = lane
                .submit_wave(vec![("act".to_string(), payment(0x11))])
                .await?;
            let (_, max_tip) = lane.sign(payment(0x11), 7, replacement_fees(quote)).await?;
            assert_eq!(
                (report[0].nonce, report[0].verdict, report[0].tx_hash),
                (7, verdict, max_tip),
                "{first} then {retry:?}"
            );
            assert!(reads.read_q().is_empty() && sends.read_q().is_empty());
        }

        // A quote whose tip is its max fee (a zero base fee) is sent once.
        let (mut lane, reads, sends) = mocked_lane();
        let mut block = Block::<alloy::rpc::types::Transaction>::default();
        block.header.inner.base_fee_per_gas = Some(0);
        reads.push_success(&U64::from(7));
        reads.push_success(&fee_history(0, GWEI));
        reads.push_success(&block);
        reads.push_success(&U256::ZERO);
        sends.push_failure_msg("replacement transaction underpriced");
        let report = lane
            .submit_wave(vec![("act".to_string(), payment(0x11))])
            .await?;
        assert_eq!(report[0].verdict, SendVerdict::Underpriced);
        assert!(reads.read_q().is_empty() && sends.read_q().is_empty());
        Ok(())
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
        // Not replacements, so not a pending transaction to wait out: a full
        // pool (geth's bare message today) and a minimum-tip policy (the
        // same message on geth 1.13 and erigon) take the max-tip retry;
        // geth's current minimum-tip wording is an error.
        assert_eq!(
            classify_submission_error(&error("transaction underpriced")),
            SubmissionErrorKind::Underpriced
        );
        assert_eq!(
            classify_submission_error(&error(
                "transaction underpriced: tip needed 1000000000, tip permitted 1"
            )),
            SubmissionErrorKind::Underpriced
        );
        assert_eq!(
            classify_submission_error(&error(
                "transaction gas price below minimum: gas tip cap 1, minimum needed 1000000000"
            )),
            SubmissionErrorKind::Other
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
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn stateless_wave_defers_to_the_pool() -> Result<()> {
        let (_anvil, provider, mut lane, signer) = spawn_lane().await?;
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

    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn rebuilding_a_wave_fills_a_dropped_prefix_and_resumes_partial_inclusion() -> Result<()>
    {
        let (_anvil, provider, mut lane, signer) = spawn_lane().await?;
        // Exactly one of these transfers fits in each block.
        provider.anvil_set_block_gas_limit(21_000).await?;
        let initial = lane
            .submit_wave(wave(&[("first", 0x11), ("second", 0x22)]))
            .await?;
        assert_eq!(initial[0].verdict, SendVerdict::Submitted);
        assert_eq!(initial[1].verdict, SendVerdict::Submitted);
        assert_eq!(
            provider.anvil_drop_transaction(initial[0].tx_hash).await?,
            Some(initial[0].tx_hash)
        );
        provider.anvil_mine(Some(1), None).await?;
        assert_eq!(
            nonces(&provider, signer).await?.0,
            0,
            "the tail cannot fill the missing prefix"
        );

        let retry = lane
            .submit_wave(wave(&[("first", 0x11), ("second", 0x22)]))
            .await?;
        assert_eq!(retry[0].nonce, 0);
        assert_eq!(retry[0].verdict, SendVerdict::Submitted);
        provider.anvil_mine(Some(1), None).await?;
        assert_eq!(nonces(&provider, signer).await?.0, 1);

        // The next observation removes the completed action. No local nonce
        // queue or receipt journal is needed to put the remainder at nonce 1.
        let remainder = lane.submit_wave(wave(&[("second", 0x22)])).await?;
        assert_eq!(remainder[0].nonce, 1);
        assert_ne!(remainder[0].verdict, SendVerdict::Failed);
        provider.anvil_mine(Some(1), None).await?;
        assert_eq!(nonces(&provider, signer).await?, (2, 2));
        Ok(())
    }

    /// An unpinned request is sized from an estimate at latest; a call that
    /// reverts there is reported, not sent, and leaves its nonce to the
    /// next request.
    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn estimates_gas_and_skips_reverting_calls() -> Result<()> {
        let (_anvil, provider, mut lane, signer) = spawn_lane().await?;
        let reverter = Address::repeat_byte(0xee);
        // PUSH1 0, PUSH1 0, REVERT
        provider
            .anvil_set_code(
                reverter,
                Bytes::from_static(&[0x60, 0x00, 0x60, 0x00, 0xfd]),
            )
            .await?;
        let unpinned = |to| TransactionRequest::default().with_to(to);

        let reports = lane
            .submit_wave(vec![
                ("reverts".to_string(), unpinned(reverter)),
                ("pays".to_string(), unpinned(Address::repeat_byte(0x11))),
            ])
            .await?;
        assert_eq!(
            verdicts(&reports),
            vec![(0, SendVerdict::Reverts), (0, SendVerdict::Submitted)]
        );
        assert_eq!(nonces(&provider, signer).await?, (0, 1));
        let sent = provider
            .get_transaction_by_hash(reports[1].tx_hash)
            .await?
            .context("the payment is pending")?;
        assert_eq!(sent.gas_limit(), gas_limit_for(21_000));
        Ok(())
    }

    /// A process restart is invisible to the pool: there is no lane
    /// state to lose, so resubmission deduplicates and a changed
    /// intent waits exactly as it would have without the restart.
    #[tokio::test]
    #[ignore = "spawns anvil, which inherits the emulator's leaked machine file locks (see harness/mod.rs); run `just test-node-harness`"]
    async fn restart_is_invisible_to_the_pool() -> Result<()> {
        let (anvil, provider, mut lane, signer) = spawn_lane().await?;

        let original = lane.submit("before-restart", payment(0x11)).await?;
        assert_eq!(original.verdict, SendVerdict::Submitted);
        drop(lane);

        let mut signer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
        signer_key.set_chain_id(Some(anvil.chain_id()));
        let mut restarted = TransactionLane::new(
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
