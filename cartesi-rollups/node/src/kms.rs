// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::{primitives::ChainId, signers::aws::AwsSigner};
use aws_config::{BehaviorVersion, timeout::TimeoutConfig};
use aws_sdk_kms::Client;

use crate::provider::REQUEST_TIMEOUT;

/// A signer over an existing KMS key; `Some(chain_id)` makes its
/// signatures EIP-155.
pub async fn kms_signer(
    key_id: String,
    chain_id: ChainId,
    region: &str,
    endpoint_url: &str,
) -> anyhow::Result<AwsSigner> {
    let client = client(region, endpoint_url).await;
    Ok(AwsSigner::new(client, key_id, Some(chain_id)).await?)
}

async fn client(region: &str, endpoint_url: &str) -> Client {
    let config = aws_config::defaults(BehaviorVersion::latest());
    // LocalStack accepts fake credentials but still requires signed
    // requests. Production builds retain the default AWS credential chain.
    #[cfg(test)]
    let config = config.test_credentials();
    // The SDK bounds only the connect by default, so a KMS endpoint that
    // accepts a call and never answers would park the manager's tick in
    // `sign` with nothing logged. Bounded like one RPC attempt, the tick
    // fails instead, and the paging rule reports it if it persists.
    let config = config
        .endpoint_url(endpoint_url.to_owned())
        .region(aws_config::Region::new(region.to_owned()))
        .timeout_config(
            TimeoutConfig::builder()
                .operation_timeout(REQUEST_TIMEOUT)
                .build(),
        )
        .load()
        .await;
    Client::new(&config)
}

#[cfg(test)]
mod tests {
    use anyhow::Context;
    use futures::FutureExt;
    use std::{
        future::Future,
        panic::{AssertUnwindSafe, resume_unwind},
        sync::LazyLock,
    };

    use alloy::{
        consensus::Transaction,
        network::{
            Ethereum, EthereumWallet, NetworkTransactionBuilder, NetworkWallet, TransactionBuilder,
        },
        primitives::Address,
        rpc::types::TransactionRequest,
        signers::Signer,
    };
    use aws_sdk_kms::types::{KeySpec, KeyUsageType};
    use testcontainers_modules::{
        localstack::LocalStack,
        testcontainers::{
            ContainerAsync, ContainerRequest, ImageExt, core::ContainerPort, runners::AsyncRunner,
        },
    };
    use tokio::sync::Mutex;

    use super::*;

    static CONTAINER_MUTEX: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

    const LOCALSTACK: &str = "http://localhost:4566";

    /// A fresh signing key in LocalStack's KMS.
    async fn create_key() -> anyhow::Result<String> {
        let result = client("us-east-1", LOCALSTACK)
            .await
            .create_key()
            .key_usage(KeyUsageType::SignVerify)
            .key_spec(KeySpec::EccSecgP256K1)
            .send()
            .await?;
        Ok(result.key_metadata.context("No metadata")?.key_id)
    }

    fn create_localstack() -> ContainerRequest<LocalStack> {
        LocalStack::default()
            .with_env_var("SERVICES", "kms")
            .with_tag("4.1.1")
            .with_mapped_port(4566, ContainerPort::Tcp(4566))
            .with_mapped_port(4566, ContainerPort::Udp(4566))
    }

    async fn setup() -> anyhow::Result<ContainerAsync<LocalStack>> {
        let image = create_localstack();
        let container_async = image.start().await?;
        Ok(container_async)
    }

    async fn teardown(container: &ContainerAsync<LocalStack>) -> anyhow::Result<()> {
        container.stop().await?;
        Ok(())
    }

    async fn run_test<T, F>(test: T) -> anyhow::Result<()>
    where
        T: FnOnce() -> F,
        F: Future<Output = ()>,
    {
        // lock
        let _guard = CONTAINER_MUTEX.lock().await;
        println!("Lock acquired");

        let container = setup().await?;

        println!("Container: {:?}", container);

        let result = AssertUnwindSafe(test()).catch_unwind().await;

        let teardown_result = teardown(&container).await;

        if let Err(payload) = result {
            resume_unwind(payload);
        }
        teardown_result?;

        // unlock
        println!("Lock released");

        Ok(())
    }

    #[tokio::test]
    #[ignore = "needs docker (LocalStack); run `just test-kms`"]
    async fn signer_works() {
        run_test(|| async {
            let key_id = create_key().await.unwrap();
            println!("Key ID: {}", key_id);
            let message = "Hello world!";

            let kms_signer = kms_signer(key_id, 1, "us-east-1", LOCALSTACK)
                .await
                .unwrap();

            println!(
                "Processing message: {}, chain_id: {:?}",
                message,
                kms_signer.chain_id()
            );
            let signature = kms_signer.sign_message(message.as_bytes()).await;
            assert!(signature.is_ok(), "Error: {:?}", signature.err().unwrap());

            let signature = signature.unwrap();
            println!("Signature: {:?}", signature);
            assert_eq!(
                signature.recover_address_from_msg(message).unwrap(),
                kms_signer.address()
            );
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    #[ignore = "needs docker (LocalStack); run `just test-kms`"]
    async fn wallet_eth() {
        run_test(|| async {
            let chain_id: ChainId = 31337;
            let key_id = create_key().await.unwrap();
            println!("Key ID: {}", key_id);

            let signer = kms_signer(key_id, chain_id, "us-east-1", LOCALSTACK)
                .await
                .unwrap();

            let wallet = EthereumWallet::from(signer);
            let wallet_address =
                <EthereumWallet as NetworkWallet<Ethereum>>::default_signer_address(&wallet);

            let envelope = TransactionRequest::default()
                .with_to(Address::repeat_byte(0x11))
                .with_chain_id(chain_id)
                .with_nonce(7)
                .with_gas_limit(21_000)
                .with_max_fee_per_gas(2_000_000_000)
                .with_max_priority_fee_per_gas(1_000_000_000)
                .build(&wallet)
                .await
                .unwrap();

            assert_eq!(
                envelope
                    .signature()
                    .recover_address_from_prehash(&envelope.signature_hash())
                    .unwrap(),
                wallet_address
            );
            assert_eq!(envelope.chain_id(), Some(chain_id));
            assert_eq!(envelope.nonce(), 7);
            println!("Wallet address: {:?}", wallet_address);
        })
        .await
        .unwrap();
    }
}
