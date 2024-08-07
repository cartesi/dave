FROM rust:1.78.0-bookworm AS chef

ENV CARGO_REGISTRIES_CARTESI_INDEX=https://github.com/cartesi/crates-index
RUN rustup component add rustfmt
RUN cargo install cargo-chef
RUN apt-get update && \
    apt-get install -y clang libslirp0

FROM chef AS planner
COPY ./machine/machine-rust-bindings /app/machine/machine-rust-bindings
COPY ./common-rs /app/common-rs
COPY ./prt/prt-rs /app/prt/prt-rs

WORKDIR /app/prt/prt-rs
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY ./machine /app/machine
COPY ./common-rs /app/common-rs
COPY ./.git /app/.git
COPY --from=planner /app/prt/prt-rs/recipe.json /app/prt/prt-rs/recipe.json

# Build dependencies - this is the caching Docker layer!
WORKDIR /app/prt/prt-rs
RUN cargo chef cook --release --recipe-path recipe.json

# Build application
COPY --from=ethereum/solc:0.8.23 /usr/bin/solc /usr/bin/solc
RUN chmod u+x /usr/bin/solc

COPY ./machine-emulator-sdk /app/machine-emulator-sdk
COPY ./prt /app/prt

WORKDIR /app/prt/prt-rs
RUN cargo build --release --bin cartesi-prt-compute

FROM --platform=linux/amd64 cartesi/machine-emulator:0.17.0

USER root
RUN apt-get update && \
    apt-get install -y procps curl xxd clang
ENV FOUNDRY_NIGHTLY nightly-5b7e4cb3c882b28f3c32ba580de27ce7381f415a
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_NIGHTLY}/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

# prepare debootstrap machine
WORKDIR /root/program
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.5-rc-test/debootstrap-machine-sparsed.tar.gz | \
    tar -zx -C /root/program

# prepare doom-showcase machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.6-rc-test/doom-compute-machine.tar.gz | \
    tar -zx -C /root/program

# prepare simple machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.7-rc-test/simple-program.tar.gz | \
    tar -zx -C /root/program

COPY ./machine-emulator-sdk /root/machine-emulator-sdk
COPY ./prt /root/prt
COPY --from=builder /app/prt/prt-rs/target/release/cartesi-prt-compute /root/prt/prt-rs/target/release/cartesi-prt-compute

WORKDIR /root/prt/contracts
RUN forge --version
RUN forge build

WORKDIR /root/prt
ENTRYPOINT ["./lua_poc/compute-test-entrypoint.sh"]
