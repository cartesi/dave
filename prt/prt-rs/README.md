# Dave PRT Compute

## Build test image

```
docker build -t cartesi/prt-compute:test -f Dockerfile.compute.test ../../
```

## Run simple test

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/simple-program" \
    --env DEPLOY_TO_ANVIL="true" \
    cartesi/prt-compute:test
```

## Run stress test

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/debootstrap-machine-sparsed" \
    --env DEPLOY_TO_ANVIL="true" \
    cartesi/prt-compute:test
```

## Run doom showcase

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/doom-compute-machine" \
    --env DEPLOY_TO_ANVIL="true" \
    cartesi/prt-compute:test
```
