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
COPY ./prt/tests/compute-rs /app/prt/tests/compute-rs

WORKDIR /app/prt/tests/compute-rs
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY ./machine /app/machine
COPY ./common-rs /app/common-rs
COPY ./prt/client-rs /app/prt/client-rs
COPY ./prt/contract-bindings /app/prt/contract-bindings
COPY ./.git /app/.git
COPY --from=planner /app/prt/tests/compute-rs/recipe.json /app/prt/tests/compute-rs/recipe.json

# Build dependencies - this is the caching Docker layer!
WORKDIR /app/prt/tests/compute-rs
RUN cargo chef cook --release --recipe-path recipe.json

# Build application
COPY --from=ethereum/solc:0.8.27 /usr/bin/solc /usr/bin/solc
RUN chmod u+x /usr/bin/solc

COPY ./prt /app/prt

WORKDIR /app/prt/tests/compute-rs
RUN cargo build --release --bin cartesi-prt-compute

FROM cartesi/machine-emulator:0.18.1

USER root
RUN apt-get update && \
    apt-get install -y procps curl xxd clang
ENV FOUNDRY_NIGHTLY nightly-805d7cee81e78e9163b8ce3d86a0c3beb39772d4
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_NIGHTLY}/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

# prepare debootstrap machine
WORKDIR /root/program
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.8-rc-test/debootstrap-machine-sparsed.tar.gz | \
    tar -zx -C /root/program

# prepare doom-showcase machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.9-rc-test/doom-compute-machine.tar.gz | \
    tar -zx -C /root/program

# prepare simple machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.10-rc-test/simple-program.tar.gz | \
    tar -zx -C /root/program

COPY ./machine/step /root/machine/step
COPY ./prt /root/prt
COPY --from=builder /app/prt/tests/compute-rs/target/release/cartesi-prt-compute /root/prt/tests/compute/cartesi-prt-compute

WORKDIR /root/prt/contracts
RUN forge --version
RUN forge build

WORKDIR /root/prt/tests/compute
ENTRYPOINT ["./entrypoint.sh"]
