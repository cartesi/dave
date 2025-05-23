// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::{
    network::{Ethereum, EthereumWallet, NetworkWallet},
    primitives::Address,
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::client::RpcClient,
    signers::local::PrivateKeySigner,
    transports::http::{Http, reqwest::Url},
};
use alloy_chains::NamedChain;
use alloy_transport::layers::RetryBackoffLayer;
use cartesi_dave_kms::{CommonSignature, KmsSignerBuilder};
use std::{fs, str::FromStr, time::Duration};

use crate::args::SignerArgs;

async fn create_signer(
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
                web3_private_key.clone().unwrap() //.unwrap_or(ANVIL_KEY_1.to_string())
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
    // let throttle = ThrottleLayer::new(20);

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

pub async fn create_provider(
    url: &Url,
    arg_chain_id: NamedChain,
    signer: &SignerArgs,
) -> (Address, DynProvider) {
    let client = create_client(url).await;
    let (address, wallet) = create_signer(arg_chain_id, signer).await;

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .with_chain(arg_chain_id)
        .on_client(client);

    let chain_id = provider
        .get_chain_id()
        .await
        .expect("failed to get chain_id from provider");
    assert_eq!(
        chain_id, arg_chain_id as u64,
        "provider chain_id does not match args chain_id"
    );

    (address, provider.erased())
}
