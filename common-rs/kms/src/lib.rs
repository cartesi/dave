use alloy::{primitives::ChainId, signers::aws::AwsSigner};
use anyhow::{self, Context};
use aws_config::BehaviorVersion;
use aws_sdk_kms::{
    types::{KeySpec, KeyUsageType},
    Client,
};

pub struct KmsSignerBuilder {
    client: Client,
    key_id: Option<String>,
    chain_id: Option<ChainId>,
}

type KmsSigner = AwsSigner;

impl KmsSignerBuilder {
    pub async fn new() -> Self {
        let config = aws_config::defaults(BehaviorVersion::v2024_03_28())
            .load()
            .await;
        let client = Client::new(&config);
        Self {
            client,
            key_id: None,
            chain_id: None,
        }
    }

    pub fn with_client(mut self, client: Client) -> Self {
        self.client = client;
        self
    }

    pub fn with_key_id(mut self, key_id: String) -> Self {
        self.key_id = Some(key_id);
        self
    }

    pub fn with_chain_id(mut self, chain_id: ChainId) -> Self {
        self.chain_id = Some(chain_id);
        self
    }

    pub async fn create_key_sign_verify(&mut self) -> anyhow::Result<&str> {
        let result = self
            .client
            .create_key()
            .key_usage(KeyUsageType::SignVerify)
            .key_spec(KeySpec::EccSecgP256K1)
            .send()
            .await?;

        let metadata = result.key_metadata.context("No metadata")?;

        self.key_id = Some(metadata.key_id);

        self.key_id.as_deref().context("No key ID")
    }

    pub async fn build(self) -> anyhow::Result<KmsSigner> {
        let key_id = self.key_id.context("No key_id")?;
        let result = KmsSigner::new(self.client, key_id, self.chain_id).await?;
        Ok(result)
    }
}

#[cfg(test)]
mod kms {
    use std::env::set_var;

    use alloy::signers::Signer;
    use aws_sdk_kms::config::Credentials;
    use testcontainers_modules::{
        localstack::LocalStack,
        testcontainers::{core::ContainerPort, runners::AsyncRunner, ContainerRequest, ImageExt},
    };

    use super::*;

    fn set_aws_test_env_vars() {
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

        set_aws_test_env_vars();
        let mut kms_signer = KmsSignerBuilder::new().await;

        let key_id = kms_signer.create_key_sign_verify().await.unwrap();
        println!("Key ID: {}", key_id);
        let message = "Hello world!";

        let kms_signer = kms_signer.build().await.unwrap();

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

        container.stop().await.unwrap();
    }
}
