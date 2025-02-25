use alloy::{
    primitives::{ChainId, PrimitiveSignature},
    signers::{aws::AwsSigner, Signer},
};
use aws_config::BehaviorVersion;
use aws_sdk_kms::types::{KeySpec, KeyUsageType};
use std::error::Error;

pub async fn create_key_sign_verify(
    client: &aws_sdk_kms::Client,
) -> Result<String, Box<dyn Error>> {
    let result = client
        .create_key()
        .key_usage(KeyUsageType::SignVerify)
        .key_spec(KeySpec::EccSecgP256K1)
        .send()
        .await?;

    let key_id = result.key_metadata.ok_or("No key_id")?.key_id;
    Ok(key_id)
}

pub async fn create_aws_client() -> Result<aws_sdk_kms::Client, Box<dyn Error>> {
    let config = aws_config::defaults(BehaviorVersion::latest()).load().await;
    let region = config.region();
    let url = config.endpoint_url();
    println!("Region: {:?}", region); // us-east-1
    println!("Endpoint URL: {:?}", url); // http://localhost:4566
    let client = aws_sdk_kms::Client::new(&config);
    Ok(client)
}

pub async fn process(
    client: aws_sdk_kms::Client,
    key_id: &str,
    chain_id: Option<ChainId>,
    message: &str,
) -> Result<(PrimitiveSignature, AwsSigner), Box<dyn Error>> {
    println!(
        "Processing message: {}, chain_id: {}",
        message,
        chain_id.unwrap_or_default()
    );
    let signer = AwsSigner::new(client, key_id.to_string(), chain_id).await?;
    let message = message.as_bytes();
    let signature = signer.sign_message(message).await?;

    println!("Signature: {:?}", signature);

    Ok((signature, signer))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[ignore = "requires LocalStack"]
    #[tokio::test]
    async fn signer_works() {
        dotenvy::from_filename("aws.env").unwrap();
        let client = create_aws_client().await.unwrap();
        let key_id = create_key_sign_verify(&client).await.unwrap();
        print!("Key ID: {}", key_id);
        let message = "Hello world!";
        let chain_id = None;

        let signature = process(client, &key_id, chain_id, message).await;
        assert!(signature.is_ok(), "Error: {:?}", signature.err().unwrap());

        let (signature, signer) = signature.unwrap();
        assert_eq!(
            signature.recover_address_from_msg(message).unwrap(),
            signer.address()
        );
    }
}
