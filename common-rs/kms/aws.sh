set -eux

curl -X POST $AWS_ENDPOINT_URL \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: TrentService.CreateKey" \
    -d '{}' | jq -C

KEY_ID=$(curl -X POST $AWS_ENDPOINT_URL \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: TrentService.ListKeys" \
    -d '{}' | jq -r ".Keys[0].KeyId // \"\"")

if [ -n "$KEY_ID" ]; then
    echo "export AWS_KMS_KEY_ID=\"$KEY_ID\"" | tee -a ~/.bashrc
else
    echo "No Key ID found."
fi

# Store AWS key ID in an environment variable for the current session
export AWS_KMS_KEY_ID="$KEY_ID"

just test-rollups-echo