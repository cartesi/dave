#!/usr/bin/env bash
# Not set -e: dependency and image checks must all run.
set -u

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'programs doctor: cannot resolve its script directory\n' >&2
    exit 2
}
programs_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    printf 'programs doctor: cannot resolve the programs directory\n' >&2
    exit 2
}
repo_root="$(CDPATH= cd -- "${programs_dir}/../.." && pwd -P)" || {
    printf 'programs doctor: cannot resolve the repository root\n' >&2
    exit 2
}
readonly script_dir programs_dir repo_root
readonly dependencies_checker="${script_dir}/download-deps.sh"
readonly fingerprint_checker="${repo_root}/script/machine-image-fingerprint.sh"

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

check_dependency() {
    local name=$1
    local checker_output="" checker_status=0 detail=""

    if checker_output="$("$dependencies_checker" check "$name" 2>&1)"; then
        ok "test/programs/${name} matches its pinned release"
        return
    else
        checker_status=$?
    fi
    detail="$(last_line "$checker_output")"
    detail="${detail#error: }"
    case "$checker_status" in
        1)
            missing "$detail" "just programs::download-deps"
            ;;
        *)
            checker_error "cannot check ${name} (${checker_status}): ${detail}"
            ;;
    esac
}

check_image() {
    local program=$1
    local fix=$2
    local checker_output="" checker_status=0 detail=""

    if checker_output="$("$fingerprint_checker" verify "$program" 2>&1)"; then
        ok "${program} machine image + fingerprint"
        return
    else
        checker_status=$?
    fi
    detail="$(last_line "$checker_output")"
    detail="${detail#error: }"
    case "$checker_status" in
        1)
            missing "${program} machine image is not usable: ${detail}" "$fix"
            ;;
        *)
            checker_error "cannot verify ${program} machine image (${checker_status}): ${detail}"
            ;;
    esac
}

printf 'Test program inputs\n'
if [[ ! -x "$dependencies_checker" ]]; then
    checker_error "dependency checker is missing or not executable: ${dependencies_checker}"
else
    check_dependency linux.bin
    check_dependency rootfs.ext2
fi
if [[ ! -x "$fingerprint_checker" ]]; then
    checker_error "fingerprint checker is missing or not executable: ${fingerprint_checker}"
else
    check_image echo "just programs::build-echo"
    check_image yield "just programs::build-yield"
    check_image honeypot \
        "ensure the devnet is current with just rollups-contracts::build-devnet, then run: just programs::build-honeypot-snapshot"
fi
printf '\n'
case "$status" in
    0) printf 'programs doctor: healthy\n' ;;
    1) printf 'programs doctor: setup required\n' ;;
    2) printf 'programs doctor: checker failure\n' ;;
esac
exit "$status"
