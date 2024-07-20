# PRT Compute in Rust

## Build test image

```
docker build -t cartesi/prt-compute:rs -f Dockerfile ../../
```

## Run simple test

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/simple-program" \
    --env DEPLOY_TO_ANVIL="true" \
    cartesi/prt-compute:rs
```

## Run stress test

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/debootstrap-machine-sparsed" \
    --env DEPLOY_TO_ANVIL="true" \
    cartesi/prt-compute:rs
```

## Run doom showcase

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/doom-compute-machine" \
    --env DEPLOY_TO_ANVIL="true" \
    cartesi/prt-compute:rs
```
