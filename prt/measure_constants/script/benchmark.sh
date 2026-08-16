#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
measure_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"
repo_root="$(CDPATH= cd -- "${measure_dir}/../.." && pwd -P)"
readonly script_dir measure_dir repo_root
readonly programs_dir="${repo_root}/test/programs"
readonly dependency_checker="${programs_dir}/script/download-deps.sh"

readonly workloads=(
    nop
    crypt
    heapsort
    tsearch
    memthrash
    matrix-3d
    tree
    tlb-shootdown
    malloc
    randlist
)

usage() {
    cat >&2 <<'EOF'
usage:
  benchmark.sh list
  benchmark.sh check [WORKLOAD ... | all]
  benchmark.sh run WORKLOAD ... | all

`check` defaults to all curated workloads. `run` requires an explicit
selection so the multi-minute benchmark is never started accidentally.
EOF
    exit 2
}

list_workloads() {
    printf '%s\n' "${workloads[@]}"
}

is_workload() {
    local candidate=$1 known
    for known in "${workloads[@]}"; do
        if [[ "$candidate" == "$known" ]]; then
            return 0
        fi
    done
    return 1
}

select_workloads() {
    local operation=$1
    shift
    if [[ "$#" -eq 0 ]]; then
        if [[ "$operation" == check ]]; then
            selected=("${workloads[@]}")
            return
        fi
        printf 'error: benchmark runs require an explicit workload or `all`\n' >&2
        usage
    fi
    if [[ "$1" == all ]]; then
        [[ "$#" -eq 1 ]] || {
            printf 'error: `all` cannot be combined with individual workloads\n' >&2
            usage
        }
        selected=("${workloads[@]}")
        return
    fi
    selected=()
    local candidate
    for candidate in "$@"; do
        if ! is_workload "$candidate"; then
            printf 'error: unsupported stress-ng workload: %s\n' "$candidate" >&2
            printf 'supported workloads:\n' >&2
            list_workloads >&2
            exit 2
        fi
        selected+=("$candidate")
    done
}

check_dependencies() {
    local asset rc=0
    for asset in linux.bin rootfs.ext2; do
        if "$dependency_checker" check "$asset"; then
            continue
        else
            rc=$?
        fi
        if [[ "$rc" -eq 1 ]]; then
            printf 'fix: just programs::download-deps\n' >&2
            exit 1
        fi
        exit "$rc"
    done
}

make_readiness_fixture() {
    local workload=$1 destination=$2
    local entrypoint
    entrypoint="stress-ng --seed 1 --${workload} 1 & stress_pid=\$!; until pgrep -P \$stress_pid >/dev/null; do kill -0 \$stress_pid || exit 1; done; yield manual rx-accepted; wait \$stress_pid"
    cartesi-machine --quiet --no-init-splash \
        --ram-image="${programs_dir}/linux.bin" \
        --flash-drive="label:root,data_filename:${programs_dir}/rootfs.ext2" \
        --revert-mode=none --store="$destination" -- "$entrypoint"
}

mode=${1:-}
case "$mode" in
    list)
        [[ "$#" -eq 1 ]] || usage
        list_workloads
        exit 0
        ;;
    check|run)
        shift
        ;;
    *)
        usage
        ;;
esac

select_workloads "$mode" "$@"

for tool in cartesi-machine lua5.4 mktemp sha256sum; do
    if ! command -v "$tool" >/dev/null; then
        printf 'error: %s is required for the emulator constants benchmark\n' "$tool" >&2
        exit 2
    fi
done
[[ -x "$dependency_checker" ]] || {
    printf 'error: dependency checker is missing or not executable: %s\n' "$dependency_checker" >&2
    exit 2
}
check_dependencies

if [[ "$mode" == run ]]; then
    make -C "$measure_dir" chronos.so
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/dave-emulator-constants.XXXXXX")"
cleanup() {
    if [[ -d "$scratch" && "$scratch" == "${TMPDIR:-/tmp}"/dave-emulator-constants.* ]]; then
        rm -rf -- "$scratch"
    fi
}
trap cleanup EXIT INT TERM

for workload in "${selected[@]}"; do
    readiness="${scratch}/${workload}-readiness"
    template="${scratch}/${workload}-template"
    printf 'Preparing active stress-ng fixture: %s\n' "$workload"
    make_readiness_fixture "$workload" "$readiness"
    LUA_PATH="${measure_dir}/?.lua;${LUA_PATH:-;;}" \
        LUA_CPATH="${measure_dir}/?.so;${LUA_CPATH:-;;}" \
        lua5.4 "${measure_dir}/measure.lua" prepare "$readiness" "$workload" "$template"
    rm -rf -- "$readiness"
    LUA_PATH="${measure_dir}/?.lua;${LUA_PATH:-;;}" \
        LUA_CPATH="${measure_dir}/?.so;${LUA_CPATH:-;;}" \
        lua5.4 "${measure_dir}/measure.lua" "$mode" "$template" "$workload"
    rm -rf -- "$template"
done
