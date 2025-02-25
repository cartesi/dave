use alloy::{
    primitives::{ChainId, PrimitiveSignature},
    signers::{aws::AwsSigner, Signer},
};
use aws_config::BehaviorVersion;
use std::error::Error;

pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

pub async fn process(
    key_id: &str,
    chain_id: Option<ChainId>,
    message: &str,
) -> Result<PrimitiveSignature, Box<dyn Error>> {
    println!(
        "Processing message: {}, chain_id: {}",
        message,
        chain_id.unwrap_or_default()
    );
    let latest = BehaviorVersion::latest();
    let config = aws_config::defaults(latest)
        .region("us-east-1")
        .load()
        .await;
    let region = config.region();
    println!("Region: {:?}", region);
    let client = aws_sdk_kms::Client::new(&config);
    let signer = AwsSigner::new(client, key_id.to_string(), chain_id).await?;
    let message = message.as_bytes();
    let signature = signer.sign_message(message).await?;

    println!("Signature: {:?}", signature);

    Ok(signature)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = add(2, 2);
        assert_eq!(result, 4);
    }

    #[tokio::test]
    async fn signer_works() {
        dotenvy::from_filename("aws.env").unwrap();

        let key_id = "6410a7e0-aa64-4bf4-b140-b0e687fa9c21";
        let msg = "Olá mundo!";
        let chain_id = None;

        let result = process(key_id, chain_id, msg).await;
        assert!(result.is_ok(), "Error: {:?}", result.err());

        // assert_eq!(signature.recover_address_from_msg(message)?, signer.address());
    }
}
