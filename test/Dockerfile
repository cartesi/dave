# syntax=docker.io/docker/dockerfile-upstream:1.12.1-labs

# start from rust
FROM rust:1.85

# install `just`
RUN \
  --mount=type=cache,target=$CARGO_HOME/registry,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/git,sharing=locked \
  --mount=type=cache,target=just-target,sharing=locked \
  cargo install just

# install `foundry`
ENV SVM_ROOT=/root/.svm
RUN \
  --mount=type=cache,target=$CARGO_HOME/registry,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/git,sharing=locked \
  --mount=type=cache,target=foundry-target,sharing=locked \
  cargo install --git https://github.com/foundry-rs/foundry \
  --profile release --locked --target-dir foundry-target \
  anvil cast chisel forge

# install general dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN \
  apt-get update && apt-get install -y --no-install-recommends \
  build-essential git wget \
  liblua5.4-dev lua5.4 \
  libslirp-dev \
  libclang-dev \
  xxd jq sqlite3; \
  rm -rf /var/cache/apt;

WORKDIR /dave

# download linux.bin and rootfs.ext2
COPY test/programs/ test/programs/
RUN just -f test/programs/justfile download-deps

# install machine
COPY machine/emulator/ machine/emulator/
WORKDIR /dave/machine/emulator
RUN make bundle-boost
RUN make
RUN make install
WORKDIR /dave

COPY prt/contracts/ prt/contracts/
COPY cartesi-rollups/contracts/ cartesi-rollups/contracts/
COPY machine/step/ machine/step/
COPY justfile justfile

# builds smart contracts and generate Rust bindings for smart contracts.
RUN \
  --mount=type=cache,target=$SVM_ROOT,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just build-smart-contracts && just bind

# builds test programs and create anvil state dump.
# requires compiled smart contracts.
RUN \
  --mount=type=cache,target=$SVM_ROOT,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just -f test/programs/justfile build-programs

COPY \
  --exclude=test/programs \
  --exclude=machine/emulator \
  --exclude=prt/contracts \
  --exclude=cartesi-rollups/contracts \
  --exclude=machine/step \
  --exclude=justfile \
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
  just build-rust-workspace; \
  cp target/debug/cartesi-rollups-prt-node .

# because of `--mount`, we need to do this.
RUN mkdir -p target/debug && mv cartesi-rollups-prt-node target/debug/
