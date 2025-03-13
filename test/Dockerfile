# syntax=docker.io/docker/dockerfile-upstream:1.12.1-labs

# to work wiht an unreleased verion, build machine docker image locally
# (i.e. cartesi/machine-emulator:latest), and change tag.
FROM cartesi/machine-emulator:0.18.1 AS machine

FROM rust:1.83

# Install `just`
RUN \
  --mount=type=cache,target=$CARGO_HOME/registry,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/git,sharing=locked \
  --mount=type=cache,target=just-target,sharing=locked \
  cargo install just

# Install `foundry`
ENV SVM_ROOT=/root/.svm
RUN \
  --mount=type=cache,target=$CARGO_HOME/registry,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/git,sharing=locked \
  --mount=type=cache,target=foundry-target,sharing=locked \
  cargo install --git https://github.com/foundry-rs/foundry \
  --profile release --locked --target-dir foundry-target \
  anvil cast chisel forge

# Install general dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN \
  apt-get update && apt-get install -y --no-install-recommends \
    build-essential git wget \
    libslirp-dev \
    liblua5.4-dev \
    lua5.4 \
    libclang-dev \
    xxd jq sqlite3; \
  rm -rf /var/cache/apt;

# Install cartesi machine
COPY \
  --from=machine \
  /usr/lib/libcartesi-0.18.so /usr/lib/libcartesi.a \
  /usr/lib/
COPY \
  --from=machine \
  /usr/bin/cartesi-machine \
  /usr/bin/
COPY \
  --from=machine \
  /usr/include/cartesi-machine/ \
  /usr/include/cartesi-machine/
COPY \
  --from=machine \
  /usr/share/lua/ \
  /usr/share/lua/
COPY \
  --from=machine \
  /usr/lib/lua/ \
  /usr/lib/lua/

# for Rust bindings `cartesi-machine-sys`
ENV LIBCARTESI_PATH="/usr/lib/"
ENV INCLUDECARTESI_PATH="/usr/include/cartesi-machine/"


WORKDIR /dave


COPY test/programs/ test/programs/
RUN just -f test/programs/justfile download-deps

COPY prt/contracts/ prt/contracts/
COPY cartesi-rollups/contracts/ cartesi-rollups/contracts/
COPY machine/step/ machine/step/
COPY justfile justfile

RUN \
  --mount=type=cache,target=$SVM_ROOT,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just build-smart-contracts && just bind

RUN \
  --mount=type=cache,target=$SVM_ROOT,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just -f test/programs/justfile build-echo


COPY \
  --exclude=test/programs \
  --exclude=prt/contracts \
  --exclude=machine/step \
  --exclude=justfile \
  --exclude=cartesi-rollups/contracts \
  . .

RUN \
  --mount=type=cache,target=target,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/registry,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/git,sharing=locked \
  --mount=type=cache,target=$SVM_ROOT,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  RUSTFLAGS="-lslirp" \
  just build-rust-workspace --features external_cartesi; \
  cp target/debug/dave-rollups .

RUN mkdir -p target/debug && mv dave-rollups target/debug/

COPY common-rs/kms/aws.sh /dave/aws.sh