update-submodules:
  git submodule update --recursive --init

clean-emulator:
  make -C machine/emulator clean depclean distclean

download-deps:
  just -f ./test/programs/justfile download-deps

build-programs:
  just -f ./test/programs/justfile build-programs

setup: update-submodules clean-emulator download-deps build-programs

build-consensus:
    just -f ./cartesi-rollups/contracts/justfile build
clean-consensus-bindings:
    just -f ./cartesi-rollups/contracts/justfile clean-bindings
bind-consensus:
    just -f ./cartesi-rollups/contracts/justfile bind

build-prt:
    just -f ./prt/contracts/justfile build
clean-prt-bindings:
    just -f ./prt/contracts/justfile clean-bindings
bind-prt:
    just -f ./prt/contracts/justfile bind

build-smart-contracts: build-consensus build-prt
bind: bind-consensus bind-prt
clean-bindings: clean-consensus-bindings clean-prt-bindings

fmt-rust-workspace: bind
  cargo fmt
check-fmt-rust-workspace: bind
  cargo fmt --check
check-rust-workspace: bind
  cargo check
test-rust-workspace: bind
  cargo test
build-rust-workspace *ARGS: bind
  cargo build {{ARGS}}
build-release-rust-workspace *ARGS: bind
  cargo build --release {{ARGS}}

build: build-smart-contracts bind build-rust-workspace



build-docker-image TAG="dave:dev":
  docker build -f test/Dockerfile -t {{TAG}} .

run-dockered +CMD: build-docker-image
  docker run -it dave:dev {{CMD}}


hello:
  echo $(echo "Hello")
