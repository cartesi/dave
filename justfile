# Dave build orchestration.
#
# Subsystem recipes live in their own justfiles, exposed here as modules:
# run `just <module>::<recipe>`, e.g. `just prt-contracts::test-disputes`.
# `just --list` shows root recipes; `just --list <module>` shows a module's.
# Modules are declared optional (mod?) so partial checkouts, like docker
# build stages, can still parse this file.

mod? prt-contracts 'prt/contracts'
mod? rollups-contracts 'cartesi-rollups/contracts'
mod? rollups-tests 'test/e2e/rollups'
mod? programs 'test/programs'
mod? machine 'machine'

# Recipe lines with pipes fail honestly instead of reporting the
# last stage's status (no recipe here pipes to head/tail, where
# pipefail would surface benign SIGPIPEs).
set shell := ["bash", "-o", "pipefail", "-cu"]

# Recipe arguments also arrive as real positional arguments ($1...),
# so recipes like `logged` can pass them through verbatim instead of
# rejoining them with spaces (which destroys shell quoting).
set positional-arguments

FOUNDRY_VERSION := "1.5.1"

[private]
default:
    @just --list

# print the Foundry release used by CI and checked by doctor
print-foundry-version:
    @echo "{{FOUNDRY_VERSION}}"

# Shell pipelines like `cmd | tail` report the LAST stage's status,
# silently laundering failures - this recipe retires that trap for
# long builds and test runs. Arguments pass through verbatim
# (positional-arguments above), so quoting survives: plain commands
# run as argv, and shell constructs work as written via
# `just logged <file> bash -c 'a && b'`.
# run a command with full output to a log file; print the tail and the TRUE exit code
logged log +cmd:
    #!/usr/bin/env bash
    set -uo pipefail
    log="$1"; shift
    status=0
    "$@" > "$log" 2>&1 || status=$?
    tail -n 40 "$log"
    echo "[logged] exit: $status (full log: $log)"
    exit $status

# ------------------------------------------------------------------
# Setup: one-time preparation. Idempotent; safe to re-run. Does NOT
# clean anything (see the clean recipes for that).
# ------------------------------------------------------------------

update-submodules:
    git submodule update --recursive --init

# Everything the Rust workspace needs to compile.
setup:
    just machine::setup

# Setup plus everything the e2e tests need, running natively.
setup-local: setup
    just prt-contracts::install-deps
    just rollups-contracts::install-deps
    just rollups-contracts::build-devnet
    just programs::download-deps
    just programs::build-programs
    just programs::build-honeypot-snapshot  # requires docker

# Setup the Docker build context without first building an unused host archive.
setup-docker: build-docker-image

# diagnose the checkout: reports what is missing and the command that fixes it
[script]
doctor:
    ./script/doctor.sh

# ------------------------------------------------------------------
# Contracts and Rust bindings
# ------------------------------------------------------------------

build-smart-contracts:
    just prt-contracts::build-smart-contracts
    just rollups-contracts::build-smart-contracts

test-smart-contracts:
    just prt-contracts::test-disputes
    just rollups-contracts::test

# validate every retained PRT refund-gas witness
test-prt-gas:
    just prt-contracts::test-gas
    just rollups-contracts::test-prt-leaf-gas

# reproduce every retained PRT refund-gas measurement and its environment
measure-prt-gas:
    just prt-contracts::measure-gas
    just rollups-contracts::measure-prt-leaf-gas

# regenerate Rust bindings from the contracts (no-op when sources unchanged)
bind:
    just prt-contracts::bind
    just rollups-contracts::bind

bind-force:
    just prt-contracts::bind-force
    just rollups-contracts::bind-force

# ------------------------------------------------------------------
# Validation. `just check` is the pre-commit gate: every fast check
# in one command, cheapest first (e2e stays separate - see the
# end-to-end section). CI runs these same targets; if you are about
# to commit, run `just check`.
# ------------------------------------------------------------------

# everything fast: formatting, lints, unit tests
check: check-fmt lint-lua test-lua-client clippy-rust-workspace test-rust-workspace

# format everything (rust workspace + both contract dirs)
fmt: fmt-rust-workspace
    just prt-contracts::fmt
    just rollups-contracts::fmt

# Forge's formatter changes wrapping heuristics across releases; when
# this disagrees with CI, align the root FOUNDRY_VERSION pin and the
# devshell forge rather than hand-formatting around either.
# check formatting everywhere (rust workspace + both contract dirs)
check-fmt: check-fmt-rust-workspace
    just prt-contracts::check-fmt
    just rollups-contracts::check-fmt

# lint the Lua client and test harness
lint-lua:
    luacheck prt/client-lua test/e2e --exclude-files "**/dependencies/**"

# fast, provider-free semantic tests for the Lua PRT client
test-lua-client:
    lua5.4 prt/client-lua/tests/run.lua

clippy-rust-workspace: bind
    cargo clippy --workspace --all-targets -- -D warnings

# ------------------------------------------------------------------
# Rust workspace. All recipes depend on bind because the bindings
# crates are generated code (gitignored); bind is incremental, so
# this costs nothing when contracts are unchanged.
# ------------------------------------------------------------------

fmt-rust-workspace: bind
    cargo fmt

check-fmt-rust-workspace: bind
    cargo fmt --check

check-rust-workspace: bind
    cargo check

# ensure-docker: the kms tests spin testcontainers, and a sleeping
# Docker Desktop fails them with noise that reads like a code bug.
# rust workspace unit tests (the kms tests spin docker testcontainers)
test-rust-workspace: bind
    ./script/ensure-docker.sh
    cargo test

# download and verify v0.21's released computation-hash corpus
download-computation-hash-corpus:
    ./script/computation-hash-corpus.sh download

# explicit release gate: cross-check the corpus against the CLI and Dave's collector
test-computation-hash-corpus: bind download-computation-hash-corpus
    ./script/computation-hash-corpus.sh test

# regenerate the measurement baselines (docs/measurements/)
measure *ARGS: bind
    ./script/machine-image-fingerprint.sh verify echo
    cargo run --release -p cartesi-rollups-prt-node --bin measure -- \
      --machine test/programs/echo/machine-image \
      --out docs/measurements/measurements.md --profile echo "$@"

measure-stress *ARGS: bind
    ./script/machine-image-fingerprint.sh verify stress
    cargo run --release -p cartesi-rollups-prt-node --bin measure -- \
      --machine test/programs/stress/machine-image \
      --out docs/measurements/measurements-stress.md --profile stress "$@"

# derive tournament level constants (docs/measurements/constants.md)
measure-constants *ARGS: bind
    ./script/machine-image-fingerprint.sh verify stress
    cargo run --release -p cartesi-rollups-prt-node --bin measure -- \
      --machine test/programs/stress/machine-image --constants \
      --out docs/measurements/constants.md --profile stress "$@"

build-rust-workspace *ARGS: bind
    cargo build "$@"

build-release-rust-workspace *ARGS: bind
    cargo build --release "$@"

build: build-smart-contracts build-rust-workspace

# ------------------------------------------------------------------
# Worktree janitor. Session worktrees accumulate regenerable bulk
# (target/ at 5-15 GB, e2e state at ~5 GB a lane) long after their
# sessions end; 2026-07-11 found ~90 GB of it. Run the report when
# disk feels tight, the sweep at the end of a work session.
# ------------------------------------------------------------------

# survey every registered worktree: size, dirtiness, last activity
worktrees-report:
    ./script/worktrees.sh report

# Copied artifacts are accepted only when their recorded inputs match
# this checkout. Machine-image fingerprints also bind the semantic
# machine root; the devnet state, deployments, and marker move as one
# bundle. Doctor verdicts the result either way.
# bootstrap a fresh worktree; SOURCE=<green sibling worktree> copies its images and devnet
bootstrap-worktree SOURCE="":
    ./script/bootstrap-worktree.sh "$@"

# Dirty worktrees are refused; sources and branches are never touched.
# remove regenerables (target/, e2e litter) from every clean session worktree except this one
worktrees-sweep:
    ./script/worktrees.sh sweep

# ------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------

clean-contracts:
    just prt-contracts::clean
    just rollups-contracts::clean

clean-rust-workspace:
    cargo clean

clean: clean-contracts clean-rust-workspace

# ------------------------------------------------------------------
# End-to-end tests (see docs/test-harness.md)
# ------------------------------------------------------------------

test-rollups-echo: build-rust-workspace
    just rollups-tests::test-echo

test-rollups-chaos: build-rust-workspace
    just rollups-tests::test-chaos

test-rollups-honeypot: build-rust-workspace
    just rollups-tests::test-honeypot-all

test-rollups-honeypot-ci: build-rust-workspace
    just rollups-tests::test-honeypot-ci

test-rollups-honeypot-stf: build-rust-workspace
    just rollups-tests::test-honeypot-stf

test-rollups-kill-ci: build-rust-workspace
    just rollups-tests::test-kill-ci

test-prt-timeout-boundaries: build-rust-workspace
    just rollups-tests::test-sealed-leaf-timeouts

test-rollups-honeypot-case CASE: build-rust-workspace
    just rollups-tests::test-honeypot-case "$1"

view-rollups-logs:
    just rollups-tests::read-node-logs

# ------------------------------------------------------------------
# Docker environment
# ------------------------------------------------------------------

[private]
prepare-docker-context:
    git submodule update --init machine/step machine/emulator
    just machine::prepare-release

build-docker-image TAG="dave:dev": prepare-docker-context
    docker build \
      --build-arg "DAVE_EMULATOR_GITLINK=$(git rev-parse :machine/emulator)" \
      -f test/Dockerfile -t "$1" .

run-dockered +CMD: build-docker-image
    docker run -it --rm --name dave-node dave:dev "$@"

exec-dockered +CMD:
    docker exec dave-node "$@"
