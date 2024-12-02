FROM rust:1.81.0-bookworm AS chef

ENV CARGO_REGISTRIES_CARTESI_INDEX=https://github.com/cartesi/crates-index
RUN rustup component add rustfmt
RUN cargo install cargo-chef
RUN apt-get update && \
    apt-get install -y clang libslirp0

FROM chef AS planner
COPY ./machine/rust-bindings /app/machine/rust-bindings
COPY ./common-rs /app/common-rs
COPY ./prt/client-rs /app/prt/client-rs
COPY ./prt/contract-bindings /app/prt/contract-bindings
COPY ./cartesi-rollups/contract-bindings /app/cartesi-rollups/contract-bindings
COPY ./cartesi-rollups/node /app/cartesi-rollups/node

WORKDIR  /app/cartesi-rollups/node
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY ./machine /app/machine
COPY ./common-rs /app/common-rs
COPY ./prt/client-rs /app/prt/client-rs
COPY ./prt/contract-bindings /app/prt/contract-bindings
COPY ./cartesi-rollups/contract-bindings /app/cartesi-rollups/contract-bindings
COPY ./.git /app/.git
COPY --from=planner /app/cartesi-rollups/node/recipe.json /app/cartesi-rollups/node/recipe.json

# Build dependencies - this is the caching Docker layer!
WORKDIR /app/cartesi-rollups/node
RUN cargo chef cook --release --recipe-path recipe.json

# Build application
COPY --from=ethereum/solc:0.8.27 /usr/bin/solc /usr/bin/solc
RUN chmod u+x /usr/bin/solc

COPY ./cartesi-rollups /app/cartesi-rollups

WORKDIR /app/cartesi-rollups/node
RUN cargo build --release --bin dave-rollups

FROM --platform=linux/amd64 cartesi/machine-emulator:0.18.1

USER root
RUN apt-get update && \
    apt-get install -y procps curl xxd clang sqlite3
ENV FOUNDRY_NIGHTLY nightly-805d7cee81e78e9163b8ce3d86a0c3beb39772d4
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_NIGHTLY}/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

# prepare echo machine
WORKDIR /root/program/
COPY ./cartesi-rollups/tests/rollups/program/echo/echo-program.tar.gz /root/program/
RUN tar -zx -f /root/program/echo-program.tar.gz

COPY ./machine/step /root/machine/step
COPY ./prt /root/prt
COPY ./cartesi-rollups /root/cartesi-rollups
COPY --from=builder /app/cartesi-rollups/node/target/release/dave-rollups /root/cartesi-rollups/tests/rollups/dave-rollups

WORKDIR /root/cartesi-rollups/contracts
RUN forge --version
RUN forge build

WORKDIR /root/cartesi-rollups/tests/rollups
ENTRYPOINT ["./prt_rollups.lua"]
