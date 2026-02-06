update-submodules:
  git submodule update --recursive --init

clean-emulator:
  make -C machine/emulator clean # don't clean the patch file

clean-contracts: clean-consensus-contracts clean-prt-contracts clean-bindings clean-deployments
  make -C machine/emulator clean # wtf? this is cleaning the emulator, not contracts

# setup the emulator locally.
# ```sh
# export PATH=$PATH:$PWD/usr/bin
# ```
setup: update-submodules clean-emulator clean-contracts
  make -C machine/emulator bundle-boost
  make -C machine/emulator uarch-with-toolchain # Requires docker, necessary for machine bindings
  make -C machine/emulator -j$(nproc) all
  make -C machine/emulator install DESTDIR=$PWD/ PREFIX=usr/

# Run this once after cloning, if using a docker environment
setup-docker: setup build-docker-image

# Run this once after cloning, if using local environment
setup-local: setup
  just -f ./prt/contracts/justfile install-deps
  just -f ./cartesi-rollups/contracts/justfile install-deps
  just -f ./cartesi-rollups/contracts/justfile build-devnet
  just -f ./test/programs/justfile download-deps
  just -f ./test/programs/justfile build-programs
  just -f ./test/programs/justfile build-honeypot-snapshot # Requires docker, necessary for tests

build-consensus:
    just -f ./cartesi-rollups/contracts/justfile build
test-consensus:
    just -f ./cartesi-rollups/contracts/justfile test
clean-consensus-contracts:
    just -f ./cartesi-rollups/contracts/justfile clean-smart-contracts
clean-consensus-bindings:
    just -f ./cartesi-rollups/contracts/justfile clean-bindings
clean-consensus-deployments:
    just -f ./cartesi-rollups/contracts/justfile clean-deployments
bind-consensus:
    just -f ./cartesi-rollups/contracts/justfile bind
build-devnet:
    just -f ./cartesi-rollups/contracts/justfile build-devnet

build-prt:
    just -f ./prt/contracts/justfile build
test-prt:
    just -f ./prt/contracts/justfile test-disputes
clean-prt-contracts:
    just -f ./prt/contracts/justfile clean-smart-contracts
clean-prt-bindings:
    just -f ./prt/contracts/justfile clean-bindings
clean-prt-deployments:
    just -f ./prt/contracts/justfile clean-deployments
bind-prt:
    just -f ./prt/contracts/justfile bind

build-smart-contracts: build-consensus build-prt
test-smart-contracts: build-smart-contracts test-consensus test-prt
bind: bind-consensus bind-prt
clean-bindings: clean-consensus-bindings clean-prt-bindings
clean-deployments: clean-consensus-deployments clean-prt-deployments

fmt-rust-workspace: bind
  cargo fmt
check-fmt-rust-workspace: bind
  cargo fmt --check
check-rust-workspace: bind
  cargo check --features download_uarch
test-rust-workspace: bind
  cargo test --features download_uarch
build-rust-workspace *ARGS: bind
  cargo build {{ARGS}} --features download_uarch
build-release-rust-workspace *ARGS: bind
  cargo build --release {{ARGS}} --features download_uarch
clean-rust-workspace: bind
  cargo clean

build: build-smart-contracts bind build-rust-workspace

build-docker-image TAG="dave:dev":
  docker build -f test/Dockerfile -t {{TAG}} .
run-dockered +CMD: build-docker-image
  docker run -it --rm --name dave-node dave:dev {{CMD}}
exec-dockered +CMD:
  docker exec dave-node {{CMD}}

test-rollups-echo: build-rust-workspace
    just -f ./prt/tests/rollups/justfile test-echo
test-rollups-honeypot: build-rust-workspace
    just -f ./prt/tests/rollups/justfile test-honeypot-all
test-rollups-honeypot-ci: build-rust-workspace
    just -f ./prt/tests/rollups/justfile test-honeypot-ci
test-rollups-honeypot-case CASE: build-rust-workspace
    just -f ./prt/tests/rollups/justfile test-honeypot-case {{CASE}}
view-rollups-logs:
    just -f ./prt/tests/rollups/justfile read-node-logs

kms-test-start:
  docker compose -f common-rs/kms/compose.yaml up --wait
kms-test-stop:
  docker compose -f common-rs/kms/compose.yaml down --volumes --remove-orphans
kms-test-restart: kms-test-stop kms-test-start
kms-test-logs:
  docker compose -f common-rs/kms/compose.yaml logs -f
kms-test-dave-logs:
  docker compose -f common-rs/kms/compose.yaml exec dave-kms tail -f ./prt/tests/rollups/dave.log
