use alloy::{
    primitives::{ChainId, Signature},
    signers::aws::AwsSigner,
};
use anyhow::{self, Context};
use aws_config::BehaviorVersion;
use aws_sdk_kms::{
    Client,
    types::{KeySpec, KeyUsageType},
};

pub type CommonSignature = dyn alloy::network::TxSigner<Signature> + Send + Sync;

pub struct KmsSignerBuilder {
    chain_id: ChainId,

    key_id: String,
    aws_endpoint_url: String,
    aws_region: aws_config::Region,
}

type KmsSigner = AwsSigner;

impl KmsSignerBuilder {
    pub fn new(key_id: &str, chain_id: ChainId) -> Self {
        let aws_region_str = "us-east-1".to_owned();
        let aws_region = aws_config::Region::new(aws_region_str.clone());
        let aws_endpoint_url = format!("https://kms.{}.amazonaws.com", aws_region_str);

        Self {
            key_id: key_id.to_owned(),
            chain_id,
            aws_region,
            aws_endpoint_url,
        }
    }

    pub fn with_key_id(mut self, key_id: String) -> Self {
        self.key_id = key_id;
        self
    }

    pub fn with_chain_id(mut self, chain_id: ChainId) -> Self {
        self.chain_id = chain_id;
        self
    }

    pub fn with_region(mut self, aws_region_str: &str) -> Self {
        let aws_region = aws_config::Region::new(aws_region_str.to_owned());
        self.aws_region = aws_region;
        self
    }

    pub fn with_endpoint(mut self, aws_endpoint_url: &str) -> Self {
        self.aws_endpoint_url = aws_endpoint_url.to_owned();
        self
    }

    pub async fn create_key_sign_verify(&mut self) -> anyhow::Result<String> {
        let client = self.new_client().await;

        let result = client
            .create_key()
            .key_usage(KeyUsageType::SignVerify)
            .key_spec(KeySpec::EccSecgP256K1)
            .send()
            .await?;

        let metadata = result.key_metadata.context("No metadata")?;

        self.key_id = metadata.key_id;
        Ok(self.key_id.clone())
    }

    pub async fn build(self) -> anyhow::Result<KmsSigner> {
        let client = self.new_client().await;
        let key_id = self.key_id;
        let result = KmsSigner::new(client, key_id, Some(self.chain_id)).await?;
        Ok(result)
    }

    async fn new_client(&self) -> Client {
        let config = aws_config::defaults(BehaviorVersion::latest())
            .endpoint_url(self.aws_endpoint_url.clone())
            .region(self.aws_region.clone())
            .load()
            .await;
        Client::new(&config)
    }
}

#[cfg(test)]
mod kms {
    use std::{
        future::Future,
        panic::{UnwindSafe, catch_unwind},
    };

    use alloy::{
        network::{Ethereum, EthereumWallet, NetworkWallet},
        signers::Signer,
    };
    use lazy_static::lazy_static;
    use testcontainers_modules::{
        localstack::LocalStack,
        testcontainers::{
            ContainerAsync, ContainerRequest, ImageExt, core::ContainerPort, runners::AsyncRunner,
        },
    };
    use tokio::sync::Mutex;

    use super::*;

    // mutex global
    lazy_static! {
        static ref CONTAINER_MUTEX: Mutex<()> = Mutex::new(());
    }

    fn new_builder() -> KmsSignerBuilder {
        KmsSignerBuilder::new("", 1)
            .with_region("us-east-1")
            .with_endpoint("http://localhost:4566")
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
        T: FnOnce() -> F + UnwindSafe,
        F: Future<Output = ()>,
    {
        // lock
        let _guard = CONTAINER_MUTEX.lock().await;
        println!("Lock acquired");

        let container = setup().await?;

        println!("Container: {:?}", container);

        let result = catch_unwind(test);

        teardown(&container).await?;

        assert!(result.is_ok());

        // unlock
        println!("Lock released");

        Ok(())
    }

    #[tokio::test]
    async fn signer_works() {
        run_test(|| async {
            let mut kms_signer = new_builder();

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
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn wallet_eth() {
        run_test(|| async {
            let chain_id: ChainId = 31337;
            let mut kms_signer = new_builder().with_chain_id(chain_id);

            let key_id = kms_signer.create_key_sign_verify().await.unwrap();
            println!("Key ID: {}", key_id);

            let signer: Box<CommonSignature>;

            let kms_signer = kms_signer.build().await.unwrap();

            signer = Box::new(kms_signer);

            let wallet = EthereumWallet::from(signer);
            let wallet_address =
                <EthereumWallet as NetworkWallet<Ethereum>>::default_signer_address(&wallet);

            println!("Wallet address: {:?}", wallet_address);
        })
        .await
        .unwrap();
    }
}
