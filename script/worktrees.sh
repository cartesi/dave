#!/usr/bin/env bash
set -uo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || {
    echo "error: cannot resolve the repository root" >&2
    exit 2
}
CDPATH= cd -- "$repo_root" || exit 2

usage() {
    cat >&2 <<'EOF'
usage:
  script/worktrees.sh report
  script/worktrees.sh sweep
EOF
    exit 2
}

worktree_name() {
    local path=${1%/}
    printf '%s\n' "${path##*/}"
}

# Megabytes under a worktree, leaving out the session roots a primary
# checkout hosts so that their worktrees are not counted twice. GNU and BSD
# du spell exclusions differently, so exclude by listing the top level.
size_mb() {
    find "$1" -mindepth 1 -maxdepth 1 ! -name .claude ! -name .codex -exec du -sk {} + \
        | awk '{ kb += $1 } END { printf "%d\n", kb / 1024 }'
}

report_records() {
    local failed=0
    local record
    local path
    local size
    local dirty
    local last
    local branch
    local name

    while IFS= read -r -d '' record; do
        case "$record" in
            'worktree '*) path=${record#worktree } ;;
            *) continue ;;
        esac

        if ! size=$(size_mb "$path"); then
            printf 'error: cannot measure worktree: %s\n' "$path" >&2
            failed=1
            continue
        fi
        if ! dirty=$(git -C "$path" status --porcelain --ignore-submodules=all | wc -l); then
            printf 'error: cannot inspect worktree status: %s\n' "$path" >&2
            failed=1
            continue
        fi
        last=$(git -C "$path" log -1 --format='%cr' 2>/dev/null || true)
        branch=$(git -C "$path" branch --show-current 2>/dev/null || true)
        name=$(worktree_name "$path")
        printf '%-42s %8s %7s %-16s %s\n' \
            "$name" "$size" "$((dirty))" "${last:-unborn}" "${branch:-detached}"
    done
    return "$failed"
}

report_worktrees() {
    printf '%-42s %8s %7s %-16s %s\n' WORKTREE SIZE_MB DIRTY LAST_COMMIT BRANCH
    if ! git worktree list --porcelain -z | report_records; then
        echo "error: failed to report every registered worktree" >&2
        return 1
    fi
}

is_session_worktree() {
    case "$1" in
        */.codex/worktrees/*|*/.claude/worktrees/*) return 0 ;;
        *) return 1 ;;
    esac
}

remove_regenerables() {
    local path=$1
    local e2e_dir
    local entries=()

    if [ -e "$path/target" ] || [ -L "$path/target" ]; then
        if ! rm -rf -- "$path/target"; then
            printf 'error: failed to remove %s\n' "$path/target" >&2
            return 1
        fi
    fi

    # prt/tests/rollups was the e2e home before 2026-08-10; worktrees on
    # older branches still keep their litter there.
    for e2e_dir in "$path/test/e2e/rollups" "$path/prt/tests/rollups"; do
        if [ ! -e "$e2e_dir" ] && [ ! -L "$e2e_dir" ]; then
            continue
        fi
        if [ -L "$e2e_dir" ]; then
            printf 'error: refusing symlinked E2E cleanup root: %s\n' "$e2e_dir" >&2
            return 1
        fi
        if [ ! -d "$e2e_dir" ]; then
            printf 'error: E2E cleanup root is not a directory: %s\n' "$e2e_dir" >&2
            return 1
        fi
        shopt -s nullglob
        entries=(
            "$e2e_dir"/_state*
            "$e2e_dir"/_oracle*
            "$e2e_dir"/_machine_scratch*
            "$e2e_dir"/_smoke
            # battery.sh's output, on branches from before 2026-10-02
            "$e2e_dir"/_battery
            "$e2e_dir"/dave*.log*
            "$e2e_dir"/anvil*.log*
        )
        shopt -u nullglob
        if [ "${#entries[@]}" -gt 0 ] && ! rm -rf -- "${entries[@]}"; then
            printf 'error: failed to remove E2E litter under %s\n' "$e2e_dir" >&2
            return 1
        fi
    done
}

sweep_records() {
    local failed=0
    local primary=1
    local record
    local path
    local canonical_path
    local dirty
    local before
    local after
    local name

    while IFS= read -r -d '' record; do
        case "$record" in
            'worktree '*) path=${record#worktree } ;;
            *) continue ;;
        esac
        if ((primary)); then
            primary=0
            if is_session_worktree "$path"; then
                printf 'skip (primary): %s\n' "$(worktree_name "$path")"
            fi
            continue
        fi
        is_session_worktree "$path" || continue
        name=$(worktree_name "$path")

        if ! canonical_path=$(CDPATH= cd -- "$path" && pwd -P); then
            printf 'error: cannot enter registered session worktree: %s\n' "$path" >&2
            failed=1
            continue
        fi
        if [ "$canonical_path" = "$repo_root" ]; then
            printf 'skip (current): %s\n' "$name"
            continue
        fi

        # Submodule pointer drift is checkout state, not user work. Any
        # other uncommitted change refuses the sweep.
        if ! dirty=$(git -C "$path" status --porcelain --ignore-submodules=all); then
            printf 'error: cannot inspect worktree status: %s\n' "$path" >&2
            failed=1
            continue
        fi
        if [ -n "$dirty" ]; then
            printf 'skip (dirty): %s\n' "$name"
            continue
        fi
        if ! before=$(size_mb "$path"); then
            printf 'error: cannot measure worktree: %s\n' "$path" >&2
            failed=1
            continue
        fi
        if ! remove_regenerables "$path"; then
            failed=1
            continue
        fi
        if ! after=$(size_mb "$path"); then
            printf 'error: cannot measure worktree: %s\n' "$path" >&2
            failed=1
            continue
        fi
        printf 'swept %s: %s MB -> %s MB\n' "$name" "$before" "$after"
    done
    return "$failed"
}

sweep_worktrees() {
    if ! git worktree list --porcelain -z | sweep_records; then
        echo "error: one or more session worktrees could not be swept" >&2
        return 1
    fi
}

[ "$#" -eq 1 ] || usage

case "$1" in
    report) report_worktrees ;;
    sweep) sweep_worktrees ;;
    *) usage ;;
esac
