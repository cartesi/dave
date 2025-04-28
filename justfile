update-submodules:
  git submodule update --recursive --init

clean-emulator:
  make -C machine/emulator clean depclean distclean

clean-contracts: clean-bindings
  just -f ./cartesi-rollups/contracts/justfile clean-smart-contracts
  just -f ./prt/contracts/justfile clean-smart-contracts

  make -C machine/emulator clean depclean distclean

setup: update-submodules clean-emulator clean-contracts
  make -C machine/emulator uarch-with-toolchain # Requries docker, necessary for machine bindings
  just -f ./test/programs/justfile build-honeypot-snapshot # Requries docker, necessary for tests

# Run this once after cloning, if using a docker environment
setup-docker: setup build-docker-image

# Run this once after cloning, if using local environment
setup-local: setup
  just -f ./prt/contracts/justfile install-deps
  just -f ./cartesi-rollups/contracts/justfile install-deps
  just -f ./test/programs/justfile download-deps
  just -f ./test/programs/justfile build-programs

build-consensus:
    just -f ./cartesi-rollups/contracts/justfile build
test-consensus:
    just -f ./cartesi-rollups/contracts/justfile test
clean-consensus-bindings:
    just -f ./cartesi-rollups/contracts/justfile clean-bindings
bind-consensus:
    just -f ./cartesi-rollups/contracts/justfile bind

build-prt:
    just -f ./prt/contracts/justfile build
test-prt:
    just -f ./prt/contracts/justfile test
clean-prt-bindings:
    just -f ./prt/contracts/justfile clean-bindings
bind-prt:
    just -f ./prt/contracts/justfile bind

build-smart-contracts: build-consensus build-prt
test-smart-contracts: build-smart-contracts test-consensus test-prt
bind: bind-consensus bind-prt
clean-bindings: clean-consensus-bindings clean-prt-bindings

fmt-rust-workspace: bind
  cargo fmt
check-fmt-rust-workspace: bind
  cargo fmt --check
check-rust-workspace: bind
  cargo check --features build_uarch
test-rust-workspace: bind
  cargo test --features build_uarch
build-rust-workspace *ARGS: bind
  cargo build {{ARGS}} --features build_uarch
build-release-rust-workspace *ARGS: bind
  cargo build --release {{ARGS}} --features build_uarch
clean-rust-workspace: bind
  cargo clean

build: build-smart-contracts bind build-rust-workspace

build-docker-image TAG="dave:dev":
  docker build -f test/Dockerfile -t {{TAG}} .
run-dockered +CMD: build-docker-image
  docker run -it --rm --name dave-node dave:dev {{CMD}}
exec-dockered +CMD:
  docker exec dave-node {{CMD}}

test-rollups-echo:
    just -f ./prt/tests/rollups/justfile test-echo
test-rollups-honeypot:
    just -f ./prt/tests/rollups/justfile test-honeypot
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
