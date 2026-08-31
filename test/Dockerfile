# syntax=docker.io/docker/dockerfile:1

ARG RUST_VERSION=1.94
ARG DEBIAN_VERSION=trixie
ARG FOUNDRY_VERSION=1.5.1
ARG JUST_VERSION=1.46.0

#### base stage
FROM rust:${RUST_VERSION}-${DEBIAN_VERSION} AS base
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/usr/bin/env", "bash", "-euo", "pipefail", "-c"]
RUN <<EOF
apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  clang \
  curl \
  git \
  jq \
  libclang-dev \
  liblua5.4-dev \
  libslirp-dev \
  libssl-dev \
  lua5.4 \
  pkg-config \
  sqlite3 \
  wget \
  xxd
EOF

#### prepare foundry
FROM base AS foundry
ARG FOUNDRY_VERSION
ARG TARGETARCH
ARG TARGETOS
RUN <<EOF
curl -fsSL https://github.com/foundry-rs/foundry/releases/download/v${FOUNDRY_VERSION}/foundry_v${FOUNDRY_VERSION}_${TARGETOS}_${TARGETARCH}.tar.gz \
  -o /tmp/foundry.tar.gz
case "${TARGETARCH}" in
    amd64) echo "73640b01bd9ed29fdb4965085099371f8cf0dbbec3e2086cf54564efc4dcfe88 /tmp/foundry.tar.gz" | sha256sum --check ;;
    arm64) echo "cccf28bdf202289e837a9e21ed213b2b80dc1e806e12f1717bc98a44315c331e /tmp/foundry.tar.gz" | sha256sum --check ;;
    *) echo "unsupported architecture: ${TARGETARCH}"; exit 1 ;;
esac
tar -zx -f /tmp/foundry.tar.gz -C /usr/local/bin
EOF

#### prepare just
FROM base AS just
ARG TARGETARCH
ARG TARGETOS
ARG JUST_VERSION

RUN <<EOF
case "${TARGETARCH}" in
    amd64)
      curl -fsSL https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-${TARGETOS}-musl.tar.gz \
        -o /tmp/just.tar.gz
      echo "79966e6e353f535ee7d1c6221641bcc8e3381c55b0d0a6dc6e54b34f9db36eaa /tmp/just.tar.gz" | sha256sum --check ;;
    arm64)
      curl -fsSL https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-aarch64-unknown-${TARGETOS}-musl.tar.gz \
        -o /tmp/just.tar.gz
      echo "b81970c8247fa64cfb30d2a3da0e487e4253f9f2d01865ed5e7d53cdc7b02188 /tmp/just.tar.gz" | sha256sum --check ;;
    *) echo "unsupported architecture: ${TARGETARCH}"; exit 1 ;;
esac
tar -zx -f /tmp/just.tar.gz -C /usr/local/bin just
EOF

#### machine-emulator build stage
FROM base AS machine-emulator

WORKDIR /dave
COPY machine/script/cartesi-machine-source.sh machine/script/cartesi-machine-source.sh
COPY machine/emulator/ machine/emulator/
RUN machine/script/cartesi-machine-source.sh prepare-boost
WORKDIR /dave/machine/emulator
ARG MAKEFLAGS="-j$(nproc)"
RUN make -C src slirp=no release=yes
ENV DESTDIR=/dave/machine/emulator/rootfs
RUN mkdir -p ${DESTDIR} && make release=yes slirp=no install

####
# final stage
FROM base

# install foundry
COPY --from=foundry /usr/local/bin/forge   /usr/local/bin/
COPY --from=foundry /usr/local/bin/cast    /usr/local/bin/
COPY --from=foundry /usr/local/bin/anvil   /usr/local/bin/
COPY --from=foundry /usr/local/bin/chisel  /usr/local/bin/

# install just
COPY --from=just /usr/local/bin/just /usr/local/bin/just

# install machine-emulator
COPY --from=machine-emulator /dave/machine/emulator/rootfs /
ENV LIBCARTESI_PATH=/usr/lib
ENV INCLUDECARTESI_PATH=/usr/include/cartesi-machine

WORKDIR /dave
COPY machine/emulator/ machine/emulator/

# download linux.bin and rootfs.ext2
COPY test/programs/ test/programs/
RUN just -f test/programs/justfile download-deps

# install solidity dependencies
COPY prt/contracts/ prt/contracts/
COPY cartesi-rollups/contracts/ cartesi-rollups/contracts/
RUN just -f prt/contracts/justfile install-deps
RUN just -f cartesi-rollups/contracts/justfile install-deps

COPY machine/step/ machine/step/
COPY justfile justfile

# builds smart contracts.
RUN \
  --mount=type=cache,target=cartesi-rollups/contracts/out,sharing=locked \
  --mount=type=cache,target=cartesi-rollups/contracts/cache,sharing=locked \
  --mount=type=cache,target=prt/contracts/out,sharing=locked \
  --mount=type=cache,target=prt/contracts/cache,sharing=locked \
  just build-smart-contracts

# generates Rust bindings for smart contracts.
# no --mount here: `forge bind --force` clears out/ and cache/, which fails on a
# mount point, and its src-only compile would evict the artifacts built above.
COPY script/contract-bindings.sh script/contract-bindings.sh
RUN just bind

# builds test programs and create anvil state dump.
# requires compiled smart contracts.
COPY script/machine-image-fingerprint.sh script/machine-image-fingerprint.sh
ARG DAVE_EMULATOR_GITLINK
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

# The build context omits Git metadata; retain the exact pin used by the image
# fingerprints so runtime doctor and verification use the same provenance.
ENV DAVE_EMULATOR_GITLINK=${DAVE_EMULATOR_GITLINK}
