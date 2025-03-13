set -eux

curl -X POST http://localstack:4566/ \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: TrentService.ListKeys" \
    -d '{}' | jq -C

just test-rollups-echo