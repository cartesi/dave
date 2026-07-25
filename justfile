# Dave build orchestration.
#
# Subsystem recipes live in their own justfiles, exposed here as modules:
# run `just <module>::<recipe>`, e.g. `just prt-contracts::test-disputes`.
# `just --list` shows root recipes; `just --list <module>` shows a module's.
# Modules are declared optional (mod?) so partial checkouts, like docker
# build stages, can still parse this file.

mod? prt-contracts 'prt/contracts'
mod? rollups-contracts 'cartesi-rollups/contracts'
mod? rollups-tests 'prt/tests/rollups'
mod? programs 'test/programs'

# Recipe lines with pipes fail honestly instead of reporting the
# last stage's status (no recipe here pipes to head/tail, where
# pipefail would surface benign SIGPIPEs).
set shell := ["bash", "-o", "pipefail", "-cu"]

# Recipe arguments also arrive as real positional arguments ($1...),
# so recipes like `logged` can pass them through verbatim instead of
# rejoining them with spaces (which destroys shell quoting).
set positional-arguments

[private]
default:
    @just --list

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

# The emulator needs generated sources that are not in its repo; they are
# fetched from the matching release and sha256-checked.

# fetch the emulator's generated sources (no-op if already applied)
apply-generated-files-diff VERSION="v0.20.0" FILEHASH="d9c2afcefc2759e7cd37bbedc83d54c81515f0fddb671103b489b8789aee33bb":
    #!/usr/bin/env bash
    set -euo pipefail
    # Guard the arg-eating trap: `just <this-recipe> <another-recipe>`
    # feeds the next recipe NAME into VERSION (just's CLI grammar; it
    # cost two days of silent CI 404s, 2026-07-20). Chain via the
    # `setup` recipe's dependency form instead.
    if [[ ! "{{VERSION}}" =~ ^v[0-9] ]]; then
      echo "error: VERSION '{{VERSION}}' does not look like a release tag." >&2
      echo "hint: another CLI word was likely consumed as this recipe's argument;" >&2
      echo "      invoke through 'just setup', or put this recipe last." >&2
      exit 2
    fi
    cd machine/emulator
    # curl over wget: wget -q swallowed the HTTP error entirely (two
    # silent exit-8 CI failures, 2026-07-20, cause invisible). -fsSL
    # is quiet on success and names the refusal on failure;
    # --retry-all-errors also retries the 403s GitHub's asset rate
    # limiter hands out. The sha256 gate below is the integrity
    # check either way, and curl exists where wget does not (macOS).
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
      -o add-generated-files.diff \
      https://github.com/cartesi/machine-emulator/releases/download/{{VERSION}}/add-generated-files.diff
    trap 'rm -f add-generated-files.diff' EXIT
    echo "{{FILEHASH}} add-generated-files.diff" | sha256sum -c -
    if git apply --check add-generated-files.diff 2>/dev/null; then
      git apply add-generated-files.diff
    elif git apply --check --reverse add-generated-files.diff 2>/dev/null; then
      echo "generated files already present; skipping"
    else
      echo "error: generated-files diff neither applies nor reverse-applies." >&2
      echo "The emulator submodule has diverged; try 'just clean-emulator' first." >&2
      exit 1
    fi

bundle-boost:
    make -C machine/emulator bundle-boost

# build the emulator natively from the submodule (C++ toolchain, no docker); no-op under LIBCARTESI_PATH
build-emulator:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${LIBCARTESI_PATH:-}" ] && [ -e "$LIBCARTESI_PATH/libcartesi.a" ]; then
      echo "build-emulator: LIBCARTESI_PATH provides libcartesi.a; skipping the submodule build"
      exit 0
    fi
    make -C machine/emulator -j8

# Everything the Rust workspace needs to compile.
setup: update-submodules bundle-boost apply-generated-files-diff build-emulator

# Setup plus everything the e2e tests need, running natively.
setup-local: setup
    just prt-contracts::install-deps
    just rollups-contracts::install-deps
    just rollups-contracts::build-devnet
    just programs::download-deps
    just programs::build-programs
    just programs::build-honeypot-snapshot  # requires docker

# Setup for the dockerized workflow.
setup-docker: setup build-docker-image

# diagnose the checkout: reports what is missing and the command that fixes it
doctor:
    #!/usr/bin/env bash
    # Not set -e: every check must run; failures are counted, not fatal.
    set -u
    fails=0; warns=0
    ok()   { printf '  ok      %s\n' "$1"; }
    miss() { printf '  MISSING %s\n' "$1"; printf '          fix: %s\n' "$2"; fails=$((fails+1)); }
    warn() { printf '  warn    %s\n' "$1"; printf '          %s\n' "$2"; warns=$((warns+1)); }

    echo "toolchain (nix users: 'direnv allow' provides all of these)"
    for tool in git cargo forge anvil cast lua5.4 luacheck jq sqlite3 \
        wget curl realpath sha256sum sort; do
      if command -v "$tool" > /dev/null; then ok "$tool"; else
        miss "$tool not on PATH" "install it (see README.md requirements)"; fi
    done
    if command -v make >/dev/null; then
      make_version=$(make --version 2>/dev/null | sed -n '1p')
      case "$make_version" in
        "GNU Make "*) ok "$make_version" ;;
        *) miss "GNU make not available" \
          "install GNU make (the nix devshell provides it)" ;;
      esac
    else
      miss "GNU make not available" \
        "install GNU make (the nix devshell provides it)"
    fi
    if command -v sort >/dev/null; then
      sort_version=$(sort --version 2>/dev/null | sed -n '1p')
      case "$sort_version" in
        *"GNU coreutils"*) ok "$sort_version" ;;
        *) miss "GNU sort not available" \
          "install GNU coreutils (the nix devshell provides it)" ;;
      esac
    fi
    if command -v docker > /dev/null; then ok "docker"; else
      warn "docker not on PATH" "needed only for the honeypot image and dockerized workflows"; fi
    if command -v xgenext2fs > /dev/null; then ok "xgenext2fs"; else
      warn "xgenext2fs not on PATH" \
        "needed only to build the honeypot image (its project generates rootfs from a tarball with it)"; fi
    # Forge formatter heuristics drift across releases; a local/CI
    # version split fails CI fmt with no local reproduction. Compare
    # against the setup-tools pin instead of documenting the advice.
    if command -v forge > /dev/null; then
      ci_pin=$(sed -n "s/.*default: 'v\([0-9][0-9.]*\)'.*/\1/p" .github/actions/setup-tools/action.yml | head -1)
      local_forge=$(forge --version 2>/dev/null | sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' | head -1)
      if [ -n "$ci_pin" ] && [ -n "$local_forge" ]; then
        if [ "$local_forge" = "$ci_pin" ]; then
          ok "forge $local_forge matches the CI pin"
        else
          warn "forge $local_forge != CI pin v$ci_pin" \
            "formatter output will differ from CI; align the flake and .github/actions/setup-tools"
        fi
      fi
    fi
    for tool in cartesi-machine cartesi-machine-stored-hash; do
      if command -v "$tool" > /dev/null; then ok "$tool"; else
        miss "$tool not on PATH" "install the Cartesi Machine (nix devshell has it), needed to build/run test programs"; fi
    done

    echo "rust build inputs"
    if [ -f machine/step/src/EmulatorConstants.sol ]; then ok "machine/step submodule"; else
      miss "machine/step submodule not initialized" "run: just update-submodules"; fi
    if [ -n "${LIBCARTESI_PATH:-}" ] && [ -e "$LIBCARTESI_PATH/libcartesi.a" ]; then
      ok "emulator library (external, LIBCARTESI_PATH)"
    elif [ -e machine/emulator/src/libcartesi.a ]; then
      ok "emulator library (submodule build)"
    else
      miss "no emulator library" "nix: 'direnv allow' (exports LIBCARTESI_PATH); otherwise run: just setup"
    fi
    for dir in prt/contracts cartesi-rollups/contracts; do
      if [ -d "$dir/dependencies" ] && [ -n "$(ls -A "$dir/dependencies" 2>/dev/null)" ]; then
        ok "$dir soldeer deps"; else
        miss "$dir/dependencies missing" "run: just setup-local (or cd $dir && just install-deps)"; fi
      if [ -d "$dir/bindings-rs/src/contract" ]; then ok "$dir bindings"; else
        miss "$dir Rust bindings not generated" "run: just bind"; fi
    done

    echo "e2e test inputs (docs/test-harness.md)"
    for f in linux.bin rootfs.ext2; do
      if [ -f "test/programs/$f" ]; then ok "test/programs/$f"; else
        miss "test/programs/$f missing" "run: just programs::download-deps"; fi
    done
    for prog in echo yield honeypot; do
      case "$prog" in
        honeypot) build_command="just programs::build-honeypot-snapshot" ;;
        *) build_command="just programs::build-$prog" ;;
      esac
      if ./script/machine-image-fingerprint.sh verify "$prog" >/dev/null 2>&1; then
        ok "$prog machine image + fingerprint"
      else
        miss "$prog machine image missing, stale, or unverified" \
          "run: $build_command (copied images need their matching fingerprint)"
      fi
    done
    if [ -f cartesi-rollups/contracts/state.json ] && [ -d cartesi-rollups/contracts/deployments/31337 ]; then
      ok "devnet state + deployments"
      # A stale devnet (contracts moved since deployment) fails e2e
      # with a winner-commitment mismatch - the scariest message in
      # the node - and cost a bisect to diagnose (2026-07-14).
      if ./script/devnet-fingerprint.sh verify >/dev/null 2>&1; then
        ok "devnet bundle fingerprint"
      else
        miss "devnet bundle is stale, mixed, or unverified" \
          "rebuild source, state, and deployments together: just rollups-contracts::build-devnet"
      fi
    else
      miss "devnet state.json / deployments missing" "run: just rollups-contracts::build-devnet"; fi
    if command -v lsof > /dev/null && lsof -iTCP:8545 -sTCP:LISTEN > /dev/null 2>&1; then
      warn "something is listening on port 8545" \
        "a stale anvil makes e2e runs nondeterministic; kill it or run tests with TEST_INSTANCE=<free port>"
    fi
    # Battery/e2e instance dirs are left for forensics and are BIG
    # (~5 GB each); a full disk quietly slows every machine store.
    litter=$(du -sm prt/tests/rollups/_state* 2>/dev/null | awk '{sum+=$1} END {printf "%d", sum}')
    if [ "${litter:-0}" -gt 10000 ]; then
      warn "e2e state dirs hold ${litter} MB (prt/tests/rollups/_state*)" \
        "forensic litter from past runs; sweep with: just rollups-tests::sweep"
    fi
    # Historic leak class (806 GB found 2026-07-11): tests that
    # tempdir().keep() into the system TMPDIR leave orphans nothing
    # sweeps. Test scratch belongs under target/ (CARGO_TARGET_TMPDIR).
    if command -v getconf > /dev/null; then
      sys_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
      if [ -n "$sys_tmp" ]; then
        tmp_litter=$(du -sm "$sys_tmp".tmp* 2>/dev/null | awk '{sum+=$1} END {printf "%d", sum}')
        if [ "${tmp_litter:-0}" -gt 10000 ]; then
          warn "system TMPDIR holds ${tmp_litter} MB of .tmp* orphans" \
            "leaked test scratch; sweep with: rm -rf \"$sys_tmp\".tmp*"
        fi
      fi
    fi

    echo
    if [ "$fails" -eq 0 ]; then
      echo "doctor: healthy ($warns warning(s)). setup docs: docs/build-system.md"
    else
      echo "doctor: $fails problem(s), $warns warning(s). setup docs: docs/build-system.md"
    fi
    exit "$fails"

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
# this disagrees with CI, align the setup-tools foundry pin and the
# devshell forge rather than hand-formatting around either.
# check formatting everywhere (rust workspace + both contract dirs)
check-fmt: check-fmt-rust-workspace
    just prt-contracts::check-fmt
    just rollups-contracts::check-fmt

# lint the Lua client and test harness
lint-lua:
    luacheck prt/client-lua prt/tests/rollups --exclude-files "**/dependencies/**"

# fast, provider-free semantic tests for the Lua PRT client
test-lua-client:
    lua5.4 prt/client-lua/tests/run.lua

clippy-rust-workspace: bind
    cargo clippy --workspace --all-targets --features download_uarch -- -D warnings

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
    cargo check --features download_uarch

# ensure-docker: the kms tests spin testcontainers, and a sleeping
# Docker Desktop fails them with noise that reads like a code bug.
# rust workspace unit tests (the kms tests spin docker testcontainers)
test-rust-workspace: bind
    ./script/ensure-docker.sh
    cargo test --features download_uarch

# regenerate the measurement baselines (docs/measurements/)
measure *ARGS: bind
    ./script/machine-image-fingerprint.sh verify echo
    cargo run --release -p cartesi-rollups-prt-node --bin measure -- \
      --machine test/programs/echo/machine-image \
      --out docs/measurements/measurements.md --profile echo {{ARGS}}

measure-stress *ARGS: bind
    ./script/machine-image-fingerprint.sh verify stress
    cargo run --release -p cartesi-rollups-prt-node --bin measure -- \
      --machine test/programs/stress/machine-image \
      --out docs/measurements/measurements-stress.md --profile stress {{ARGS}}

# derive tournament level constants (docs/measurements/constants.md)
measure-constants *ARGS: bind
    ./script/machine-image-fingerprint.sh verify stress
    cargo run --release -p cartesi-rollups-prt-node --bin measure -- \
      --machine test/programs/stress/machine-image --constants \
      --out docs/measurements/constants.md --profile stress {{ARGS}}

build-rust-workspace *ARGS: bind
    cargo build {{ARGS}} --features download_uarch

build-release-rust-workspace *ARGS: bind
    cargo build --release {{ARGS}} --features download_uarch

build: build-smart-contracts build-rust-workspace

# ------------------------------------------------------------------
# Worktree janitor. Session worktrees accumulate regenerable bulk
# (target/ at 5-15 GB, e2e state at ~5 GB a lane) long after their
# sessions end; 2026-07-11 found ~90 GB of it. Run the report when
# disk feels tight, the sweep at the end of a work session.
# ------------------------------------------------------------------

# survey every registered worktree: size, dirtiness, last activity
worktrees-report:
    #!/usr/bin/env bash
    set -u
    printf '%-42s %8s %7s %-16s %s\n' WORKTREE SIZE DIRTY LAST_COMMIT BRANCH
    git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
      # Exclude .claude: the main checkout hosts the session
      # worktrees under .claude/worktrees; count each tree once.
      # GNU du (nix devshell) and BSD du (stock macOS) disagree on
      # the flag.
      size=$(du -sh --exclude=.claude "$wt" 2>/dev/null | cut -f1)
      [ -z "$size" ] && size=$(du -sh -I .claude "$wt" 2>/dev/null | cut -f1)
      dirty=$(git -C "$wt" status --porcelain --ignore-submodules=all 2>/dev/null | wc -l | tr -d ' ')
      last=$(git -C "$wt" log -1 --format='%cr' 2>/dev/null)
      branch=$(git -C "$wt" branch --show-current 2>/dev/null)
      printf '%-42s %8s %7s %-16s %s\n' \
        "$(basename "$wt")" "$size" "$dirty" "$last" "${branch:-detached}"
    done

# Copied artifacts are accepted only when their recorded inputs match
# this checkout. Machine-image fingerprints also bind the semantic
# machine root; the devnet state, deployments, and marker move as one
# bundle. Doctor verdicts the result either way.
# bootstrap a fresh worktree; SOURCE=<green sibling worktree> copies its images and devnet
bootstrap-worktree SOURCE="":
    #!/usr/bin/env bash
    set -euo pipefail
    source_root="${1:-}"
    target_root=$(pwd -P)
    if [ -n "$source_root" ]; then
      source_root=$(cd "$source_root" && pwd -P)
      if [ "$source_root" = "$target_root" ]; then
        echo "error: SOURCE must be a different worktree" >&2
        exit 2
      fi
    fi

    git submodule update --init machine/step
    just prt-contracts::install-deps
    just rollups-contracts::install-deps
    just bind

    if [ -n "$source_root" ]; then
      for f in linux.bin rootfs.ext2; do
        if [ -f "$source_root/test/programs/$f" ] && [ ! -f "test/programs/$f" ]; then
          cp "$source_root/test/programs/$f" "test/programs/$f"
          echo "copied $f"
        fi
      done

      devnet_dir=cartesi-rollups/contracts
      target_devnet_valid=0
      if ./script/devnet-fingerprint.sh verify "$devnet_dir" >/dev/null 2>&1; then
        target_devnet_valid=1
        echo "kept verified target devnet bundle"
      fi

      if [ "$target_devnet_valid" -eq 0 ]; then
        source_devnet="$source_root/$devnet_dir"
        rm -rf "$devnet_dir/state.json" "$devnet_dir/state.fingerprint" \
          "$devnet_dir/deployments"
        if ./script/devnet-fingerprint.sh verify "$source_devnet" \
            >/dev/null 2>&1; then
          cp "$source_devnet/state.json" "$devnet_dir/state.json"
          cp -R "$source_devnet/deployments" "$devnet_dir/deployments"
          cp "$source_devnet/state.fingerprint" "$devnet_dir/state.fingerprint"
          ./script/devnet-fingerprint.sh verify "$devnet_dir" >/dev/null
          echo "copied verified devnet bundle"
        else
          echo "source devnet is incomplete or stale; rebuilding"
          just rollups-contracts::build-devnet
        fi
      fi

      for prog in echo yield honeypot; do
        image="test/programs/$prog/machine-image"
        manifest="test/programs/$prog/machine-image.fingerprint"
        if ./script/machine-image-fingerprint.sh verify "$prog" >/dev/null 2>&1; then
          echo "kept verified $prog machine image"
          continue
        fi

        source_image="$source_root/$image"
        source_manifest="$source_root/$manifest"
        rm -rf "$image" "$manifest"
        if ./script/machine-image-fingerprint.sh verify "$prog" \
            "$source_image" "$source_manifest" >/dev/null 2>&1; then
          cp -R "$source_image" "$image"
          cp "$source_manifest" "$manifest"
          echo "copied verified $prog machine image"
        else
          echo "source $prog machine image is missing, stale, or unverified"
        fi
      done
    fi
    just doctor

# Dirty worktrees are refused; sources and branches are never touched.
# remove regenerables (target/, e2e litter) from every clean session worktree except this one
worktrees-sweep:
    #!/usr/bin/env bash
    set -u
    here=$(pwd -P)
    git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
      case "$wt" in
        */.claude/worktrees/*) ;;    # session worktrees only
        *) continue ;;               # never the main checkout
      esac
      [ "$(cd "$wt" && pwd -P)" = "$here" ] && continue
      # Submodule pointer drift is checkout state, not user work;
      # any real uncommitted change refuses the sweep.
      if [ -n "$(git -C "$wt" status --porcelain --ignore-submodules=all 2>/dev/null)" ]; then
        echo "skip (dirty): $(basename "$wt")"
        continue
      fi
      before=$(du -sm "$wt" 2>/dev/null | cut -f1)
      rm -rf "$wt/target"
      (cd "$wt/prt/tests/rollups" 2>/dev/null \
        && shopt -s nullglob \
        && rm -rf _state* _oracle* _machine_scratch* _battery dave*.log* anvil*.log)
      after=$(du -sm "$wt" 2>/dev/null | cut -f1)
      echo "swept $(basename "$wt"): ${before:-?} MB -> ${after:-?} MB"
    done

# ------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------

clean-emulator:
    make -C machine/emulator clean depclean distclean

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
    just rollups-tests::test-honeypot-case {{CASE}}

view-rollups-logs:
    just rollups-tests::read-node-logs

# ------------------------------------------------------------------
# Docker environment
# ------------------------------------------------------------------

build-docker-image TAG="dave:dev":
    docker build -f test/Dockerfile -t {{TAG}} .

run-dockered +CMD: build-docker-image
    docker run -it --rm --name dave-node dave:dev {{CMD}}

exec-dockered +CMD:
    docker exec dave-node {{CMD}}

# ------------------------------------------------------------------
# KMS test harness
# ------------------------------------------------------------------

kms-test-start:
    docker compose -f common-rs/kms/compose.yaml up --wait

kms-test-stop:
    docker compose -f common-rs/kms/compose.yaml down --volumes --remove-orphans

kms-test-restart: kms-test-stop kms-test-start

kms-test-logs:
    docker compose -f common-rs/kms/compose.yaml logs -f

kms-test-dave-logs:
    docker compose -f common-rs/kms/compose.yaml exec dave-kms tail -f ./prt/tests/rollups/dave.log
