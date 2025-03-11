# Dave Common Library

In localstack for create a KMS key you need this command using [AWS LOCAL](https://github.com/localstack/awscli-local):

```bash
awslocal kms create-key --key-usage SIGN_VERIFY --key-spec ECC_SECG_P256K1
```