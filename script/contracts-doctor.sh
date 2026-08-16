#!/usr/bin/env bash
# Not set -e: dependency and binding checks must both run.
set -u

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'contracts doctor: cannot resolve its script directory\n' >&2
    exit 2
}
repo_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    printf 'contracts doctor: cannot resolve the repository root\n' >&2
    exit 2
}
readonly script_dir repo_dir
readonly bindings_script="${script_dir}/contract-bindings.sh"

usage() {
    printf 'usage: script/contracts-doctor.sh prt|rollups\n' >&2
    exit 2
}

module=${1:-}
[[ "$#" -eq 1 ]] || usage
case "$module" in
    prt)
        readonly contracts_dir="${repo_dir}/prt/contracts"
        readonly display_name="PRT"
        readonly recipe_prefix="prt-contracts"
        ;;
    rollups)
        readonly contracts_dir="${repo_dir}/cartesi-rollups/contracts"
        readonly display_name="Rollups"
        readonly recipe_prefix="rollups-contracts"
        ;;
    *) usage ;;
esac
readonly module

status=0

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

last_line() {
    local value=$1

    value="${value%$'\n'}"
    printf '%s\n' "${value##*$'\n'}"
}

check_dependencies() {
    local config_output="" targets_output="" target="" entry=""
    local find_status=0 target_count=0

    if ! config_output="$(
        CDPATH= cd -- "$contracts_dir" && forge config --json 2>&1
    )"; then
        checker_error "cannot read the effective Forge configuration: $(last_line "$config_output")"
        return
    fi
    if ! targets_output="$(
        printf '%s\n' "$config_output" | jq -r '
            [.remappings[]?
                | select(type == "string")
                | select(test("^[^=]+=dependencies/"))
                | sub("^[^=]+="; "")]
            | unique[]
        ' 2>&1
    )"; then
        checker_error "cannot read dependency remappings: $(last_line "$targets_output")"
        return
    fi
    if [[ -z "$targets_output" ]]; then
        checker_error "the effective Forge configuration has no dependency remappings"
        return
    fi

    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        target_count=$((target_count + 1))
        if [[ ! -d "${contracts_dir}/${target}" ]]; then
            missing "Soldeer dependency ${target} is missing" \
                "just ${recipe_prefix}::install-deps"
            continue
        fi
        entry="$(find "${contracts_dir}/${target}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        find_status=$?
        if ((find_status != 0)); then
            checker_error "cannot inspect Soldeer dependency ${target}"
        elif [[ -z "$entry" ]]; then
            missing "Soldeer dependency ${target} is empty" \
                "just ${recipe_prefix}::install-deps"
        else
            ok "Soldeer dependency ${target}"
        fi
    done <<<"$targets_output"

    if ((target_count == 0)); then
        checker_error "the effective Forge configuration has no usable dependency remappings"
    fi
}

check_bindings() {
    local output="" rc=0

    output="$("$bindings_script" verify "$module" 2>&1)"
    rc=$?
    case "$rc" in
        0) ok "${display_name} Rust bindings match the current inputs" ;;
        1)
            missing "${display_name} Rust bindings are missing or stale: $(last_line "$output")" \
                "just ${recipe_prefix}::bind"
            ;;
        *)
            checker_error "cannot verify ${display_name} Rust bindings: $(last_line "$output")"
            ;;
    esac
}

printf '%s contract build inputs\n' "$display_name"
check_dependencies
check_bindings
printf '\n'
case "$status" in
    0) printf '%s contracts doctor: healthy\n' "$module" ;;
    1) printf '%s contracts doctor: setup required\n' "$module" ;;
    2) printf '%s contracts doctor: checker failure\n' "$module" ;;
esac
exit "$status"
