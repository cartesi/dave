# syntax=docker.io/docker/dockerfile:1

ARG RUST_VERSION=1.86
ARG FOUNDRY_VERSION=1.4.3
ARG PNPM_VERSION=10.7.0
ARG JUST_VERSION=1.46.0

#### base stage
FROM rust:${RUST_VERSION} AS base
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
    amd64) echo "325ba04dc5cb41c110723b00ac291f8269f8cd785028299aad8252ef980961a7 /tmp/foundry.tar.gz" | sha256sum --check ;;
    arm64) echo "209492cb4ebd723d9eac002fa30f41f53c8810105b67d3c32fe8201cf70f89d4 /tmp/foundry.tar.gz" | sha256sum --check ;;
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
COPY machine/emulator/ machine/emulator/
WORKDIR /dave/machine/emulator
RUN make bundle-boost
ARG MAKEFLAGS="-j$(nproc)"
RUN make -C src slirp=no release=yes
ENV DESTDIR=/dave/machine/emulator/rootfs
RUN mkdir -p ${DESTDIR} && make install

#### pnpm stage
FROM base AS pnpm
ARG TARGETARCH
ARG TARGETOS
ARG PNPM_VERSION

RUN <<EOF
case "${TARGETARCH}" in
    amd64)
      curl -fsSL https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-${TARGETOS}-x64 \
        -o /usr/local/bin/pnpm
      echo "d1e8009b1ac8c54050efd969d4b6a96eae4fdc3e1ed138741eaf5699a85a16cf /usr/local/bin/pnpm" | sha256sum --check ;;
    arm64)
      curl -fsSL https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-${TARGETOS}-arm64 \
        -o /usr/local/bin/pnpm
      echo "68916f9fadde7cfea9eced8d88f3a2159d181b1fe5a1e405a71434fc05643405 /usr/local/bin/pnpm" | sha256sum --check ;;
    *) echo "unsupported architecture: ${TARGETARCH}"; exit 1 ;;
esac
chmod 755 /usr/local/bin/pnpm
EOF

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

WORKDIR /dave
COPY machine/emulator/ machine/emulator/

# download linux.bin and rootfs.ext2
COPY test/programs/ test/programs/
RUN just -f test/programs/justfile download-deps

# install pnpm
COPY --from=pnpm /usr/local/bin/pnpm /usr/local/bin/pnpm

# install solidity dependencies
COPY prt/contracts/ prt/contracts/
COPY cartesi-rollups/contracts/ cartesi-rollups/contracts/
ARG PNPM_INSTALL_ARGS=""
ARG PNPM_CI=true
RUN just -f prt/contracts/justfile install-deps "${PNPM_INSTALL_ARGS}" "${PNPM_CI}"
RUN just -f cartesi-rollups/contracts/justfile install-deps "${PNPM_INSTALL_ARGS}" "${PNPM_CI}"

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
