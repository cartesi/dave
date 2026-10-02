#!/usr/bin/env bash
# Diagnose a checkout without changing it. Each checker it calls exits 0 when
# healthy, 1 when an artifact is missing or stale (a fix applies), and 2 when
# it cannot decide; the doctor exits with the worst of those. Not set -e:
# every check runs. Only the forge pin comparison asks Just, which may be what
# is broken, and it falls back to a warning.
set -u

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
cd "$repo_root" || exit 2

usage() {
    printf 'usage: script/doctor.sh [base|e2e|all]\n' >&2
    exit 2
}

scope=${1:-base}
(($# <= 1)) || usage
case "$scope" in base | e2e | all) ;; *) usage ;; esac
readonly scope

misses=0 warns=0 errors=0
ok() { printf '  ok      %s\n' "$1"; }
miss() {
    printf '  MISSING %s\n          fix: %s\n' "$1" "$2"
    misses=$((misses + 1))
}
warn() {
    printf '  warn    %s\n          %s\n' "$1" "$2"
    warns=$((warns + 1))
}
error() {
    printf '  ERROR   %s\n' "$1"
    errors=$((errors + 1))
}

# check LABEL FIX CHECKER...: report a checker's verdict, quoting the last
# line of its output as the diagnostic.
check() {
    local label=$1 fix=$2 output status
    shift 2
    output="$("$@" 2>&1)"
    status=$?
    output="${output%$'\n'}"
    output="${output##*$'\n'}"
    output="${output#error: }"
    case "$status" in
        0) ok "$label" ;;
        1) miss "${label}: ${output}" "$fix" ;;
        *) error "${label}: checker failed (${status}): ${output}" ;;
    esac
}

check_toolchain() {
    local tool make_version pin local_forge

    echo "toolchain (nix users: 'direnv allow' provides all of these)"
    for tool in git just cargo forge lua5.4 luacheck jq sqlite3 \
        cartesi-machine cartesi-machine-stored-hash curl realpath sha256sum; do
        if command -v "$tool" >/dev/null; then
            ok "$tool"
        else
            miss "$tool not on PATH" "install it (see README.md requirements)"
        fi
    done
    make_version="$(make --version 2>/dev/null | sed -n '1p')"
    case "$make_version" in
        "GNU Make "*) ok "$make_version" ;;
        *) miss "GNU make not available" "install GNU make (the nix devshell provides it)" ;;
    esac
    # Forge formatter heuristics drift across releases; a local/CI version
    # split fails CI fmt with no local reproduction.
    if command -v forge >/dev/null && command -v just >/dev/null; then
        pin="$(just --justfile justfile print-foundry-version 2>/dev/null)"
        local_forge="$(forge --version 2>/dev/null |
            sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
        if [[ -z "$pin" || -z "$local_forge" ]]; then
            warn "cannot compare forge with the CI pin" \
                "check that just print-foundry-version and forge --version both print a version"
        elif [[ "$local_forge" == "$pin" ]]; then
            ok "forge $local_forge matches the CI pin"
        else
            warn "forge $local_forge != CI pin v$pin" \
                "formatter output will differ from CI; align the devshell and FOUNDRY_VERSION in the root justfile"
        fi
    fi
}

check_e2e_tools() {
    local tool

    echo "e2e toolchain"
    for tool in anvil cast; do
        if command -v "$tool" >/dev/null; then
            ok "$tool"
        else
            miss "$tool not on PATH" "install it (the nix devshell provides the E2E toolchain)"
        fi
    done
    if ! command -v xgenext2fs >/dev/null; then
        warn "xgenext2fs not on PATH" "needed to rebuild the opt-in Honeypot image"
    fi
    if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
        warn "docker daemon is unavailable" \
            "needed only to rebuild the Honeypot image and for just test-kms"
    fi
}

check_machine() {
    local step provider=source fix="just machine::setup"

    echo "Cartesi Machine"
    step="$(git submodule status -- machine/step 2>&1)"
    case "$step" in
        " "*)
            git -C machine/step diff --quiet HEAD --
            case $? in
                0) ok "machine/step matches its pinned commit" ;;
                1) miss "machine/step has local changes" "commit or restore them, then rerun the doctor" ;;
                *) error "cannot inspect machine/step for local changes" ;;
            esac
            ;;
        -*) miss "machine/step is not initialized" "just machine::setup" ;;
        +*) miss "machine/step is not at its pinned commit" "resolve any local work, then run: just machine::setup" ;;
        *) error "cannot read the machine/step submodule: ${step##*$'\n'}" ;;
    esac
    if [[ -n "${LIBCARTESI_PATH+x}" ]]; then
        provider=external
        fix="repair the external provider or unset LIBCARTESI_PATH, then run: just machine::setup"
    fi
    check "Cartesi Machine ${provider} provider" "$fix" \
        machine/script/cartesi-machine-source.sh check
}

check_contracts() {
    local module=$1 dir=$2 recipe=$3 targets target absent=""

    echo "${module} contracts"
    targets="$(cd "$dir" && forge config --json 2>/dev/null | jq -r '
        .remappings[]? | sub("^[^=]+="; "") | select(startswith("dependencies/"))')"
    if [[ -z "$targets" ]]; then
        error "cannot read the ${module} dependency remappings from forge config"
    else
        while IFS= read -r target; do
            [[ -n "$(ls -A "${dir}/${target}" 2>/dev/null)" ]] || absent+=" ${target}"
        done <<<"$targets"
        if [[ -z "$absent" ]]; then
            ok "Soldeer dependencies"
        else
            miss "Soldeer dependencies are missing or empty:${absent}" "just ${recipe}::install-deps"
        fi
    fi
    check "Rust bindings" "just ${recipe}::bind" script/contract-bindings.sh verify "$module"
}

check_programs() {
    local name program

    echo "test programs"
    for name in linux.bin rootfs.ext2; do
        check "test/programs/${name} matches its pin" "just programs::download-deps" \
            test/programs/script/download-deps.sh check "$name"
    done
    for program in echo yield; do
        check "${program} machine image" "just programs::build-${program}" \
            script/machine-image-fingerprint.sh verify "$program"
    done
    # Opt-in: an absent honeypot image is fine, a stale one is not.
    if [[ "$scope" != base && -e test/programs/honeypot/machine-image ]]; then
        check "honeypot machine image" \
            "ensure the devnet is current with just rollups-contracts::build-devnet, then run: just programs::build-honeypot" \
            script/machine-image-fingerprint.sh verify honeypot
    fi
}

check_e2e_inputs() {
    local litter_mb sys_tmp tmp_litter

    echo "e2e inputs (docs/test-harness.md)"
    check "devnet state, deployments, and fingerprint" \
        "rebuild source, state, and deployments together: just rollups-contracts::build-devnet" \
        script/devnet-fingerprint.sh verify
    if command -v lsof >/dev/null && lsof -iTCP:8545 -sTCP:LISTEN >/dev/null 2>&1; then
        warn "something is listening on port 8545" \
            "a stale anvil makes E2E runs nondeterministic; kill it or use TEST_INSTANCE=<free port>"
    fi
    litter_mb="$(cd test/e2e/rollups && du -sm _state* _oracle* _machine_scratch* _smoke \
        dave*.log* anvil*.log* 2>/dev/null | awk '{sum += $1} END {printf "%d", sum}')"
    if ((${litter_mb:-0} > 10000)); then
        warn "E2E forensic state holds ${litter_mb} MB" \
            "read any retained results, then sweep with: just rollups-tests::sweep"
    fi
    # Historic leak class (806 GB found 2026-07-11): tests that
    # tempdir().keep() into the system TMPDIR leave orphans nothing sweeps.
    # Test scratch belongs under target/ (CARGO_TARGET_TMPDIR).
    sys_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
    if [[ -n "$sys_tmp" ]]; then
        tmp_litter="$(du -sm "$sys_tmp".tmp* 2>/dev/null | awk '{sum += $1} END {printf "%d", sum}')"
        if ((${tmp_litter:-0} > 10000)); then
            warn "system TMPDIR holds ${tmp_litter} MB of .tmp* orphans" \
                "leaked test scratch; sweep with: rm -rf \"$sys_tmp\".tmp*"
        fi
    fi
}

check_toolchain
[[ "$scope" == base ]] || check_e2e_tools
if [[ "$scope" != e2e ]]; then
    check_machine
    check_contracts prt prt/contracts prt-contracts
    check_contracts rollups cartesi-rollups/contracts rollups-contracts
fi
check_programs
[[ "$scope" == base ]] || check_e2e_inputs

echo
status=0
((misses == 0)) || status=1
((errors == 0)) || status=2
verdicts=(healthy "setup required" "checker failure")
printf 'doctor (%s): %s (%d missing, %d warning(s), %d checker error(s)). setup docs: docs/build-system.md\n' \
    "$scope" "${verdicts[status]}" "$misses" "$warns" "$errors"
exit "$status"
