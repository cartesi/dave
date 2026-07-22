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
use anyhow::{Context, Result, anyhow, ensure};
use log::{debug, trace};
use std::{fs, str::FromStr, sync::Arc, time::Duration};
use tokio::sync::Mutex;

const MAX_SEND_ATTEMPTS: usize = 3;

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

/// The one replaceable transaction slot owned by the node signer.
///
/// The slot never consults pending state. It reads the account nonce using the
/// `latest` block tag, signs a fully specified transaction, and submits the raw
/// bytes without waiting for a receipt. Until inclusion advances the mined
/// nonce, every caller rebroadcasts or replaces that same nonce instead of
/// creating a queue behind it.
#[derive(Clone, Debug)]
pub struct TransactionLane {
    read_provider: DynProvider,
    submit_provider: DynProvider,
    signer_address: Address,
    chain_id: u64,
    wallet: EthereumWallet,
    slot: Arc<Mutex<SlotState>>,
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
            slot: Arc::new(Mutex::new(SlotState::default())),
        }
    }

    pub const fn signer_address(&self) -> Address {
        self.signer_address
    }

    /// Submit one fully specified call through the exclusive signer slot.
    ///
    /// Identical work at the same mined nonce rebroadcasts the exact signed
    /// bytes unless a fresh market quote has risen. Changed work and explicit
    /// underpriced responses replace at a monotonic fee floor.
    pub async fn submit(&self, label: &str, request: TransactionRequest) -> Result<Submission> {
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

        let fingerprint = request_fingerprint(&request)?;
        let mut slot = self.slot.lock().await;
        let nonce = self.mined_nonce_at_latest().await?;
        let quoted_fees = self.read_provider.estimate_eip1559_fees().await;
        let same_nonce = slot
            .attempt
            .as_ref()
            .is_some_and(|attempt| attempt.nonce == nonce);
        let reuse_exact = should_rebroadcast_exact(
            slot.attempt.as_ref(),
            nonce,
            fingerprint,
            quoted_fees.as_ref().ok().copied(),
        );

        if !reuse_exact {
            let fees = match quoted_fees {
                Ok(quoted) => next_fees(slot.attempt.as_ref(), nonce, quoted),
                Err(error) if same_nonce => {
                    trace!(
                        "fee quote failed for {label}; replacing nonce {nonce} from retained floor: {error}"
                    );
                    bump_fees(
                        slot.attempt
                            .as_ref()
                            .expect("same nonce has an attempt")
                            .fees,
                    )
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to estimate fees for {label}"));
                }
            };
            slot.attempt = Some(
                self.sign_attempt(request.clone(), nonce, fingerprint, fees)
                    .await
                    .with_context(|| format!("failed to sign {label} transaction"))?,
            );
        } else {
            trace!("rebroadcast exact {label} transaction at nonce {nonce}");
        }

        for send_attempt in 0..MAX_SEND_ATTEMPTS {
            let attempt = slot
                .attempt
                .as_ref()
                .expect("the transaction attempt is initialized above");
            let raw = attempt.raw.clone();
            let submission = attempt.submission();

            match self.submit_provider.send_raw_transaction(&raw).await {
                Ok(_pending) => {
                    debug!(
                        "submitted {label} transaction {} at nonce {} with max fee {} and priority fee {}",
                        submission.tx_hash,
                        submission.nonce,
                        submission.max_fee_per_gas,
                        submission.max_priority_fee_per_gas
                    );
                    return Ok(submission);
                }
                Err(error) => match classify_submission_error(&error) {
                    SubmissionErrorKind::AlreadyKnown => {
                        trace!(
                            "{label} transaction {} is already known at nonce {}",
                            submission.tx_hash, submission.nonce
                        );
                        return Ok(submission);
                    }
                    SubmissionErrorKind::ReplacementUnderpriced
                        if send_attempt + 1 < MAX_SEND_ATTEMPTS =>
                    {
                        let bumped = bump_fees(slot.attempt.as_ref().unwrap().fees);
                        slot.attempt = Some(
                            self.sign_attempt(request.clone(), nonce, fingerprint, bumped)
                                .await
                                .with_context(|| {
                                    format!("failed to re-sign underpriced {label} replacement")
                                })?,
                        );
                    }
                    SubmissionErrorKind::NonceTooLow => {
                        return Err(anyhow!(
                            "{label} transaction nonce {nonce} is already mined; re-observe latest state: {error}"
                        ));
                    }
                    _ => {
                        // Keep the signed attempt. Even a deterministic
                        // rejection is safe to retry, while a transport
                        // failure may have reached the submit provider.
                        return Err(anyhow!(
                            "failed to submit {label} transaction {} at nonce {nonce}: {error}",
                            submission.tx_hash
                        ));
                    }
                },
            }
        }

        unreachable!("bounded submission loop always returns")
    }

    async fn mined_nonce_at_latest(&self) -> Result<u64> {
        self.read_provider
            .get_transaction_count(self.signer_address)
            .latest()
            .await
            .context("failed to read signer nonce at latest mined state")
    }

    async fn sign_attempt(
        &self,
        mut request: TransactionRequest,
        nonce: u64,
        fingerprint: B256,
        fees: Eip1559Estimation,
    ) -> Result<SlotAttempt> {
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
        Ok(SlotAttempt {
            nonce,
            fingerprint,
            fees,
            raw,
            tx_hash,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Submission {
    pub nonce: u64,
    pub tx_hash: B256,
    pub max_fee_per_gas: u128,
    pub max_priority_fee_per_gas: u128,
}

#[derive(Debug, Default)]
struct SlotState {
    attempt: Option<SlotAttempt>,
}

#[derive(Clone, Debug)]
struct SlotAttempt {
    nonce: u64,
    fingerprint: B256,
    fees: Eip1559Estimation,
    raw: Vec<u8>,
    tx_hash: B256,
}

impl SlotAttempt {
    const fn submission(&self) -> Submission {
        Submission {
            nonce: self.nonce,
            tx_hash: self.tx_hash,
            max_fee_per_gas: self.fees.max_fee_per_gas,
            max_priority_fee_per_gas: self.fees.max_priority_fee_per_gas,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SubmissionErrorKind {
    AlreadyKnown,
    NonceTooLow,
    ReplacementUnderpriced,
    Other,
}

fn request_fingerprint(request: &TransactionRequest) -> Result<B256> {
    let encoded =
        serde_json::to_vec(request).context("failed to fingerprint transaction request")?;
    Ok(keccak256(encoded))
}

fn next_fees(
    previous: Option<&SlotAttempt>,
    nonce: u64,
    quoted: Eip1559Estimation,
) -> Eip1559Estimation {
    let quoted = normalize_fees(quoted);
    match previous {
        Some(previous) if previous.nonce == nonce => max_fees(quoted, bump_fees(previous.fees)),
        _ => quoted,
    }
}

fn should_rebroadcast_exact(
    previous: Option<&SlotAttempt>,
    nonce: u64,
    fingerprint: B256,
    quoted: Option<Eip1559Estimation>,
) -> bool {
    let Some(previous) =
        previous.filter(|attempt| attempt.nonce == nonce && attempt.fingerprint == fingerprint)
    else {
        return false;
    };
    quoted.is_none_or(|quoted| !fees_exceed(quoted, previous.fees))
}

fn fees_exceed(quoted: Eip1559Estimation, current: Eip1559Estimation) -> bool {
    let quoted = normalize_fees(quoted);
    quoted.max_fee_per_gas > current.max_fee_per_gas
        || quoted.max_priority_fee_per_gas > current.max_priority_fee_per_gas
}

fn bump_fees(fees: Eip1559Estimation) -> Eip1559Estimation {
    normalize_fees(Eip1559Estimation {
        max_fee_per_gas: bump_fee(fees.max_fee_per_gas),
        max_priority_fee_per_gas: bump_fee(fees.max_priority_fee_per_gas),
    })
}

fn bump_fee(fee: u128) -> u128 {
    fee.saturating_add((fee / 8).max(1))
}

fn max_fees(left: Eip1559Estimation, right: Eip1559Estimation) -> Eip1559Estimation {
    normalize_fees(Eip1559Estimation {
        max_fee_per_gas: left.max_fee_per_gas.max(right.max_fee_per_gas),
        max_priority_fee_per_gas: left
            .max_priority_fee_per_gas
            .max(right.max_priority_fee_per_gas),
    })
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

    fn fees(max_fee_per_gas: u128, max_priority_fee_per_gas: u128) -> Eip1559Estimation {
        Eip1559Estimation {
            max_fee_per_gas,
            max_priority_fee_per_gas,
        }
    }

    #[test]
    fn fee_floor_only_resets_when_mined_nonce_changes() {
        let previous = SlotAttempt {
            nonce: 7,
            fingerprint: B256::repeat_byte(0x11),
            fees: fees(100, 8),
            raw: Vec::new(),
            tx_hash: B256::ZERO,
        };

        assert_eq!(next_fees(Some(&previous), 7, fees(90, 7)), fees(112, 9));
        assert_eq!(next_fees(Some(&previous), 7, fees(150, 20)), fees(150, 20));
        assert_eq!(next_fees(Some(&previous), 8, fees(90, 7)), fees(90, 7));

        assert!(should_rebroadcast_exact(
            Some(&previous),
            7,
            previous.fingerprint,
            None
        ));
        assert!(should_rebroadcast_exact(
            Some(&previous),
            7,
            previous.fingerprint,
            Some(fees(100, 8))
        ));
        assert!(!should_rebroadcast_exact(
            Some(&previous),
            7,
            previous.fingerprint,
            Some(fees(101, 8))
        ));
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

    #[tokio::test]
    async fn disabled_automining_replaces_latest_nonce_without_queueing_next_nonce() -> Result<()> {
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
        let before_submissions = read_provider.anvil_snapshot().await?;

        let mut signer: PrivateKeySigner = anvil.keys()[0].clone().into();
        signer.set_chain_id(Some(anvil.chain_id()));
        let signer_address = signer.address();
        let lane = TransactionLane::new(
            read_provider.clone(),
            submit_provider,
            anvil.chain_id(),
            EthereumWallet::from(signer),
        );

        let first = lane
            .submit(
                "first",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x11))
                    .with_gas_limit(21_000),
            )
            .await?;
        assert_eq!(first.nonce, 0);
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .latest()
                .await?,
            0
        );
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .pending()
                .await?,
            1
        );

        let rebroadcast = lane
            .submit(
                "first-again",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x11))
                    .with_gas_limit(21_000),
            )
            .await?;
        assert_eq!(rebroadcast, first);
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .pending()
                .await?,
            1,
            "exact rebroadcast must not allocate another nonce"
        );

        let replacement = lane
            .submit(
                "replacement",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x22))
                    .with_gas_limit(21_000),
            )
            .await?;
        assert_eq!(replacement.nonce, 0);
        assert_ne!(replacement.tx_hash, first.tx_hash);
        assert!(replacement.max_fee_per_gas > first.max_fee_per_gas);
        assert!(replacement.max_priority_fee_per_gas > first.max_priority_fee_per_gas);
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .pending()
                .await?,
            1,
            "replacement must not allocate nonce 1 while latest nonce is 0"
        );

        read_provider.anvil_mine(Some(1), None).await?;
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .latest()
                .await?,
            1
        );

        let next = lane
            .submit(
                "next",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x33))
                    .with_gas_limit(21_000),
            )
            .await?;
        assert_eq!(next.nonce, 1);

        assert!(read_provider.anvil_revert(before_submissions).await?);
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .latest()
                .await?,
            0
        );

        let after_reorg = lane
            .submit(
                "after-reorg",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x44))
                    .with_gas_limit(21_000),
            )
            .await?;
        assert_eq!(
            after_reorg.nonce, 0,
            "a rolled-back mined nonce must be reusable without lane reconciliation"
        );

        Ok(())
    }

    #[tokio::test]
    async fn restart_recovers_from_underpriced_replacement_at_latest_nonce() -> Result<()> {
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
        let wallet = EthereumWallet::from(signer);
        let lane = TransactionLane::new(
            read_provider.clone(),
            submit_provider.clone(),
            anvil.chain_id(),
            wallet.clone(),
        );

        let original = lane
            .submit(
                "before-restart",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x11))
                    .with_gas_limit(21_000),
            )
            .await?;
        drop(lane);

        // The fresh lane has lost the pending transaction's fee floor. Its
        // first same-nonce send uses the unchanged block quote, so Anvil
        // rejects it as underpriced and exercises the reactive retry path.
        let restarted_lane = TransactionLane::new(
            read_provider.clone(),
            submit_provider,
            anvil.chain_id(),
            wallet,
        );
        let replacement = restarted_lane
            .submit(
                "after-restart",
                TransactionRequest::default()
                    .with_to(Address::repeat_byte(0x22))
                    .with_gas_limit(21_000),
            )
            .await?;

        assert_eq!(replacement.nonce, original.nonce);
        assert_ne!(replacement.tx_hash, original.tx_hash);
        assert_eq!(
            fees(
                replacement.max_fee_per_gas,
                replacement.max_priority_fee_per_gas
            ),
            bump_fees(fees(
                original.max_fee_per_gas,
                original.max_priority_fee_per_gas
            ))
        );
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .latest()
                .await?,
            original.nonce
        );
        assert_eq!(
            read_provider
                .get_transaction_count(signer_address)
                .pending()
                .await?,
            original.nonce + 1,
            "replacement retry must not allocate a nonce after the pending slot"
        );

        Ok(())
    }
}
