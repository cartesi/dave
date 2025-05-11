// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use alloy::{
    network::{Ethereum, EthereumWallet, NetworkWallet},
    primitives::Address,
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::client::RpcClient,
    signers::local::PrivateKeySigner,
};
use alloy_transport::layers::RetryBackoffLayer;
use cartesi_dave_kms::{CommonSignature, KmsSignerBuilder};
use std::{fs, str::FromStr};

use crate::args::{PRTArgs, SignerArgs};

// const ANVIL_KEY_1: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

async fn create_signer(args: &PRTArgs) -> (Address, EthereumWallet) {
    let signer: Box<CommonSignature> = match &args.signer {
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

            let kms_signer = KmsSignerBuilder::new(&key_id, args.web3_chain_id)
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

async fn create_client(args: &PRTArgs) -> RpcClient {
    // let throttle = ThrottleLayer::new(20);

    let retry = RetryBackoffLayer::new(
        5,   // max_rate_limit_retries
        200, // initial_backoff_ms
        500, // compute_units_per_sec
    );

    RpcClient::builder()
        // .layer(throttle)
        .layer(retry)
        .http(args.web3_rpc_url.clone())
}

pub async fn create_provider(args: &PRTArgs) -> (Address, DynProvider) {
    let client = create_client(args).await;
    let (address, wallet) = create_signer(args).await;

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .with_chain(
            args.web3_chain_id
                .try_into()
                .expect("fail to convert chain id"),
        )
        .on_client(client);

    let chain_id = provider
        .get_chain_id()
        .await
        .expect("failed to get chain_id from provider");
    assert_eq!(
        chain_id, args.web3_chain_id,
        "provider chain_id does not match args chain_id"
    );

    (address, provider.erased())
}
