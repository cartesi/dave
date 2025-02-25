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
    let config = aws_config::defaults(BehaviorVersion::v2024_03_28())
        .load()
        .await;
    let client = aws_sdk_kms::Client::new(&config);
    Ok(client)
}

pub async fn process(
    client: aws_sdk_kms::Client,
    key_id: &str,
    chain_id: Option<ChainId>,
    message: &str,
) -> Result<(PrimitiveSignature, AwsSigner), Box<dyn Error>> {
    let signer = AwsSigner::new(client, key_id.to_string(), chain_id).await?;
    let message = message.as_bytes();
    let signature = signer.sign_message(message).await?;

    Ok((signature, signer))
}

#[cfg(test)]
mod tests {
    use std::env::set_var;

    use aws_sdk_kms::config::Credentials;
    use testcontainers_modules::{
        localstack::LocalStack,
        testcontainers::{core::ContainerPort, runners::AsyncRunner, ContainerRequest, ImageExt},
    };

    use super::*;

    fn aws_test_credentials() {
        let test_credentials = Credentials::for_tests();
        set_var("AWS_ACCESS_KEY_ID", test_credentials.access_key_id());
        set_var(
            "AWS_SECRET_ACCESS_KEY",
            test_credentials.secret_access_key(),
        );
        set_var("AWS_ENDPOINT_URL", "http://localhost:4566");
        set_var("AWS_REGION", "us-east-1");
    }

    fn create_localstack() -> ContainerRequest<LocalStack> {
        LocalStack::default()
            .with_env_var("SERVICES", "kms")
            .with_tag("4.1.1")
            .with_mapped_port(4566, ContainerPort::Tcp(4566))
            .with_mapped_port(4566, ContainerPort::Udp(4566))
    }

    #[tokio::test]
    async fn signer_works() {
        let image = create_localstack();
        let container = image.start().await.unwrap();

        println!("Container: {:?}", container);

        aws_test_credentials();
        let client = create_aws_client().await.unwrap();
        let key_id = create_key_sign_verify(&client).await.unwrap();
        println!("Key ID: {}", key_id);
        let message = "Hello world!";
        let chain_id = None;

        println!("Processing message: {}, chain_id: {:?}", message, chain_id);
        let signature = process(client, &key_id, chain_id, message).await;
        assert!(signature.is_ok(), "Error: {:?}", signature.err().unwrap());

        let (signature, signer) = signature.unwrap();
        println!("Signature: {:?}", signature);
        assert_eq!(
            signature.recover_address_from_msg(message).unwrap(),
            signer.address()
        );

        container.stop().await.unwrap();
    }
}
