# PRT Compute in Rust

## Generate Rust bindings

Refer to [contract-bindings](../contract-bindings/README.md)

## Build test image

Requires bindings generated from [previous section](#generate-rust-bindings).

```
docker build -t cartesi/prt-compute:rs -f Dockerfile ../../../
```

## Run simple test

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/simple-program" \
    --env LUA_NODE="false" \
    cartesi/prt-compute:rs
```

## Run stress test

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/debootstrap-machine-sparsed" \
    --env LUA_NODE="false" \
    cartesi/prt-compute:rs
```

## Run doom showcase

Requires image built from [previous section](#build-test-image).

```
docker run --rm \
    --env MACHINE_PATH="/root/program/doom-compute-machine" \
    --env LUA_NODE="false" \
    cartesi/prt-compute:rs
```
