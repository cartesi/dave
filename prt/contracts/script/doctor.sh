#!/usr/bin/env bash
# Not set -e: dependency and binding checks must both run.
set -u

readonly script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly contracts_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"
readonly repo_dir="$(CDPATH= cd -- "${contracts_dir}/../.." && pwd -P)"
readonly bindings_script="${repo_dir}/script/contract-bindings.sh"

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
    local value="$1"

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
                "just prt-contracts::install-deps"
            continue
        fi
        entry="$(find "${contracts_dir}/${target}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        find_status=$?
        if ((find_status != 0)); then
            checker_error "cannot inspect Soldeer dependency ${target}"
        elif [[ -z "$entry" ]]; then
            missing "Soldeer dependency ${target} is empty" \
                "just prt-contracts::install-deps"
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

    output="$("$bindings_script" verify prt 2>&1)"
    rc=$?
    case "$rc" in
        0) ok "PRT Rust bindings match the current inputs" ;;
        1)
            missing "PRT Rust bindings are missing or stale: $(last_line "$output")" \
                "just prt-contracts::bind"
            ;;
        *)
            checker_error "cannot verify PRT Rust bindings: $(last_line "$output")"
            ;;
    esac
}

printf 'PRT contract build inputs\n'
check_dependencies
check_bindings
printf '\n'
case "$status" in
    0) printf 'prt-contracts doctor: healthy\n' ;;
    1) printf 'prt-contracts doctor: setup required\n' ;;
    2) printf 'prt-contracts doctor: checker failure\n' ;;
esac
exit "$status"
