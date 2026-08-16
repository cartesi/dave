#!/usr/bin/env bash
# Not set -e: the step and provider checks must both run.
set -u

readonly script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly machine_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"
readonly repo_root="$(CDPATH= cd -- "${machine_dir}/.." && pwd -P)"
readonly provider_checker="${script_dir}/cartesi-machine-source.sh"

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

check_step() {
    local actual="" expected="" index_record="" mode="" stage="" path="" extra=""
    local diff_status=0 dirty=0 pin_mismatch=0

    if ! index_record="$(git -C "$repo_root" ls-files --stage -- machine/step 2>&1)"; then
        checker_error "cannot read the machine/step gitlink: $(last_line "$index_record")"
        return
    fi
    read -r mode expected stage path extra <<<"$index_record"
    if [[ "$mode" != "160000" || "$stage" != "0" || "$path" != "machine/step" ||
        -n "${extra:-}" ]]; then
        checker_error "the superproject index has no valid machine/step gitlink"
        return
    fi

    if [[ ! -e "${machine_dir}/step/.git" ]]; then
        missing "machine/step is not initialized" "just machine::setup"
        return
    fi
    if ! actual="$(git -C "${machine_dir}/step" rev-parse --verify HEAD 2>&1)"; then
        checker_error "cannot read machine/step HEAD: $(last_line "$actual")"
        return
    fi
    if [[ "$actual" != "$expected" ]]; then
        pin_mismatch=1
    fi

    git -C "${machine_dir}/step" diff --quiet --
    diff_status=$?
    case "$diff_status" in
        0) ;;
        1)
            missing "machine/step has tracked worktree changes" \
                "commit or restore the tracked changes, then rerun: just machine::doctor"
            dirty=1
            ;;
        *)
            checker_error "cannot inspect machine/step worktree changes"
            return
            ;;
    esac

    git -C "${machine_dir}/step" diff --cached --quiet --
    diff_status=$?
    case "$diff_status" in
        0) ;;
        1)
            missing "machine/step has staged changes" \
                "commit or restore the staged changes, then rerun: just machine::doctor"
            dirty=1
            ;;
        *)
            checker_error "cannot inspect machine/step staged changes"
            return
            ;;
    esac

    if ((pin_mismatch)); then
        if ((dirty)); then
            missing "machine/step is at ${actual}, expected ${expected}" \
                "resolve the local changes, then run: just machine::setup"
        else
            missing "machine/step is at ${actual}, expected ${expected}" \
                "run: just machine::setup"
        fi
    fi

    if ((dirty || pin_mismatch)); then
        return
    fi
    ok "machine/step matches the pinned gitlink"
}

check_provider() {
    local checker_output="" checker_status=0 detail fix provider

    if checker_output="$("$provider_checker" check 2>&1)"; then
        if [[ "${LIBCARTESI_PATH+x}" == "x" ]]; then
            provider="external"
        else
            provider="source"
        fi
        ok "Cartesi Machine ${provider} provider is ready"
        return
    else
        checker_status=$?
    fi

    detail="$(last_line "$checker_output")"
    detail="${detail#error: }"
    if [[ -z "$detail" ]]; then
        detail="provider check produced no diagnostic"
    fi
    if ((checker_status == 1)); then
        if [[ "${LIBCARTESI_PATH+x}" == "x" ]]; then
            fix="repair the external provider or unset LIBCARTESI_PATH, then run: just machine::setup"
        else
            fix="run: just machine::setup; intermediary commits use generate-sources, prepare-boost, and build"
        fi
        missing "$detail" "$fix"
    else
        checker_error "Cartesi Machine provider checker failed (${checker_status}): ${detail}"
    fi
}

printf 'Cartesi Machine build inputs\n'
check_step
check_provider
printf '\n'
case "$status" in
    0) printf 'machine doctor: healthy\n' ;;
    1) printf 'machine doctor: setup required\n' ;;
    2) printf 'machine doctor: checker failure\n' ;;
esac
exit "$status"
