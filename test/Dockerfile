# syntax=docker.io/docker/dockerfile-upstream:1.12.1-labs

#### prepare tools
FROM rust:1.85 AS tools
# foundry
ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
set -eu
apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git
curl -L https://foundry.paradigm.xyz | bash
~/.foundry/bin/foundryup --install stable
install -Dm755 ~/.foundry/bin/* /usr/local/bin/
EOF
# cargo binstall (to install just)
RUN curl -L --proto '=https' --tlsv1.2 -sSf \
    https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
    | bash
ENV BINSTALL_YES=1 \
    CARGO_TERM_COLOR=never
# just
RUN cargo binstall just --no-confirm
####

# start from rust
FROM rust:1.86

# install general dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN \
  apt-get update && apt-get install -y --no-install-recommends \
  build-essential git wget \
  liblua5.4-dev lua5.4 \
  libclang-dev \
  xxd jq sqlite3; \
  rm -rf /var/cache/apt;

# install foundry
COPY --from=tools /usr/local/bin/forge   /usr/local/bin/
COPY --from=tools /usr/local/bin/cast    /usr/local/bin/
COPY --from=tools /usr/local/bin/anvil   /usr/local/bin/
COPY --from=tools /usr/local/bin/chisel  /usr/local/bin/

# install just
COPY --from=tools /usr/local/cargo/bin/  /usr/local/bin/

WORKDIR /dave

ENV ANVIL_IP_ADDR="0.0.0.0"
EXPOSE 8545
# download linux.bin and rootfs.ext2

COPY test/programs/ test/programs/
RUN just -f test/programs/justfile download-deps

# install machine
COPY machine/emulator/ machine/emulator/
WORKDIR /dave/machine/emulator
RUN make bundle-boost
RUN make -C src slirp=no release=yes && make install
# RUN make -C src clean
WORKDIR /dave

# install solidity dependencies
COPY prt/contracts/ prt/contracts/
COPY cartesi-rollups/contracts/ cartesi-rollups/contracts/
RUN just -f prt/contracts/justfile install-deps
RUN just -f cartesi-rollups/contracts/justfile install-deps

COPY machine/step/ machine/step/
COPY justfile justfile

# builds smart contracts and generate Rust bindings for smart contracts.
RUN \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just build-smart-contracts && just bind

# builds test programs and create anvil state dump.
# requires compiled smart contracts.
RUN \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just -f test/programs/justfile build-programs

# copy everything else
COPY \
  --exclude=test/programs \
  --exclude=machine/emulator \
  --exclude=prt/contracts \
  --exclude=cartesi-rollups/contracts \
  --exclude=machine/step \
  --exclude=justfile \
  . .

# build rust workspace
RUN \
  --mount=type=cache,target=target,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/registry,sharing=locked \
  --mount=type=cache,target=$CARGO_HOME/git,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just build-rust-workspace; \
  cp target/debug/cartesi-rollups-prt-node .

# because of `--mount`, we need to do this.
RUN mkdir -p target/debug && mv cartesi-rollups-prt-node target/debug/
