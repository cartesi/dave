# KMS Signer

In [localstack](https://docs.localstack.cloud/user-guide/aws/kms/) for create a KMS key you need this command using [AWS LOCAL](https://github.com/localstack/awscli-local):

```bash
awslocal kms create-key --key-usage SIGN_VERIFY --key-spec ECC_SECG_P256K1
```

For list keys:
```bash
awslocal kms list-keys
```

For more details:
```bash
awslocal kms describe-key --key-id KEY_HERE
```

Run command from PRT Compute:

```bash
cargo run -p cartesi-prt-compute -- \
    --aws-access-key-id KEY_ID \
    --aws-secret-access-key SECRET_ACCESS_KEY \
    --aws-endpoint-url ENDPOINT \
    --aws-region REGION \
    --web3-chain-id CHAIN_ID
```
