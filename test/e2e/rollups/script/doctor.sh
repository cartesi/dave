#!/usr/bin/env bash
# Not set -e: devnet and hygiene checks must all run.
set -u

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'rollups-e2e doctor: cannot resolve its script directory\n' >&2
    exit 2
}
e2e_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    printf 'rollups-e2e doctor: cannot resolve the E2E directory\n' >&2
    exit 2
}
repo_root="$(CDPATH= cd -- "${e2e_dir}/../../.." && pwd -P)" || {
    printf 'rollups-e2e doctor: cannot resolve the repository root\n' >&2
    exit 2
}
readonly script_dir e2e_dir repo_root
readonly devnet_dir="${repo_root}/cartesi-rollups/contracts"
readonly fingerprint_checker="${repo_root}/script/devnet-fingerprint.sh"
readonly legacy_e2e_dir="${repo_root}/prt/tests/rollups"

status=0
warns=0

ok() {
    printf '  ok      %s\n' "$1"
}

missing() {
    printf '  MISSING %s\n' "$1"
    printf '          fix: %s\n' "$2"
    if ((status == 0)); then
        status=1
    fi
}

checker_error() {
    printf '  ERROR   %s\n' "$1"
    status=2
}

warn() {
    printf '  warn    %s\n' "$1"
    printf '          %s\n' "$2"
    warns=$((warns + 1))
}

last_line() {
    local value=$1

    value="${value%$'\n'}"
    printf '%s\n' "${value##*$'\n'}"
}

check_devnet() {
    local checker_ready=1 bundle_ready=1
    local checker_output="" detail=""
    local tool="" probe_output=""

    if [[ ! -x "$fingerprint_checker" ]]; then
        checker_error "devnet fingerprint checker is missing or not executable: ${fingerprint_checker}"
        checker_ready=0
    fi
    for tool in anvil forge git jq sha256sum sort; do
        if ! command -v "$tool" >/dev/null; then
            checker_error "cannot verify the devnet bundle: ${tool} is not on PATH"
            checker_ready=0
        fi
    done

    # command -v also accepts broken exported shell shims. Exercise each
    # primitive so an operational checker failure is not reported as staleness.
    if ((checker_ready)); then
        for tool in anvil forge git jq sha256sum sort; do
            case "$tool" in
                anvil|forge|git|jq) probe_output="$("$tool" --version 2>&1)" ;;
                sha256sum) probe_output="$(printf '' | sha256sum 2>&1)" ;;
                sort) probe_output="$(printf 'b\na\n' | sort 2>&1)" ;;
            esac
            if [[ $? -ne 0 || -z "$probe_output" ]]; then
                checker_error "cannot run ${tool} while verifying the devnet bundle"
                checker_ready=0
            fi
        done
    fi

    if [[ ! -s "${devnet_dir}/state.json" ]]; then
        missing "devnet state.json is missing or empty" \
            "just rollups-contracts::build-devnet"
        bundle_ready=0
    fi
    if [[ ! -d "${devnet_dir}/deployments/31337" ]]; then
        missing "devnet deployments/31337 is missing" \
            "just rollups-contracts::build-devnet"
        bundle_ready=0
    fi
    if [[ ! -s "${devnet_dir}/state.fingerprint" ]]; then
        missing "devnet state.fingerprint is missing or empty" \
            "just rollups-contracts::build-devnet"
        bundle_ready=0
    fi

    if ((checker_ready && bundle_ready)); then
        if checker_output="$("$fingerprint_checker" verify "$devnet_dir" 2>&1)"; then
            ok "devnet state, deployments, and fingerprint"
        else
            detail="$(last_line "$checker_output")"
            detail="${detail#error: }"
            [[ -n "$detail" ]] || detail="fingerprint verification failed"
            missing "devnet bundle is stale, mixed, or unverified: ${detail}" \
                "rebuild source, state, and deployments together: just rollups-contracts::build-devnet"
        fi
    fi
}

check_default_port() {
    if command -v lsof >/dev/null \
        && lsof -iTCP:8545 -sTCP:LISTEN >/dev/null 2>&1; then
        warn "something is listening on port 8545" \
            "a stale anvil makes E2E runs nondeterministic; kill it or use TEST_INSTANCE=<free port>"
    fi
}

check_forensic_litter() {
    local dir="" pattern="" path="" litter_output="" litter_mb="" detail=""
    local -a litter_paths=()
    local -a patterns=(
        '_state*'
        '_oracle*'
        '_machine_scratch*'
        '_battery'
        'dave*.log*'
        'anvil*.log*'
    )

    if ! command -v du >/dev/null || ! command -v awk >/dev/null; then
        checker_error "cannot measure E2E forensic litter: du and awk are required"
        return
    fi

    shopt -s nullglob
    for dir in "$e2e_dir" "$legacy_e2e_dir"; do
        [[ -d "$dir" ]] || continue
        for pattern in "${patterns[@]}"; do
            for path in "$dir"/$pattern; do
                [[ -e "$path" || -L "$path" ]] || continue
                litter_paths+=("$path")
            done
        done
    done
    shopt -u nullglob

    if ((${#litter_paths[@]} == 0)); then
        return
    fi
    if ! litter_output="$(du -sm "${litter_paths[@]}" 2>&1)"; then
        detail="$(last_line "$litter_output")"
        [[ -n "$detail" ]] || detail="du failed"
        checker_error "cannot measure E2E forensic litter: ${detail}"
        return
    fi
    if ! litter_mb="$(printf '%s\n' "$litter_output" \
        | awk '{sum += $1} END {printf "%d", sum}')"; then
        checker_error "cannot total E2E forensic litter"
        return
    fi
    if ((litter_mb > 10000)); then
        warn "E2E forensic state holds ${litter_mb} MB (including legacy locations)" \
            "read any retained results, then sweep with: just rollups-tests::sweep"
    fi
}

printf 'Rollups E2E inputs (docs/test-harness.md)\n'
check_devnet
check_default_port
check_forensic_litter
printf '\n'
case "$status" in
    0) printf 'rollups-e2e doctor: healthy (%d warning(s))\n' "$warns" ;;
    1) printf 'rollups-e2e doctor: setup required (%d warning(s))\n' "$warns" ;;
    2) printf 'rollups-e2e doctor: checker failure (%d warning(s))\n' "$warns" ;;
esac
exit "$status"
