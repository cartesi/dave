#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    echo "error: cannot resolve the bootstrap script directory" >&2
    exit 2
}
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    echo "error: cannot resolve the target worktree" >&2
    exit 2
}
readonly script_dir repo_root
readonly dependency_checker="${repo_root}/test/programs/script/download-deps.sh"
readonly devnet_checker="${repo_root}/script/devnet-fingerprint.sh"
readonly image_checker="${repo_root}/script/machine-image-fingerprint.sh"

usage() {
    echo "usage: script/bootstrap-worktree.sh [SOURCE]" >&2
    exit 2
}

require_physical_directory() {
    local path=$1
    local physical=""

    if ! physical="$(CDPATH= cd -- "$path" 2>/dev/null && pwd -P)"; then
        echo "error: missing bootstrap target directory: $path" >&2
        return 2
    fi
    if [[ "$physical" != "$path" ]]; then
        echo "error: refusing symlinked bootstrap target directory: $path" >&2
        return 2
    fi
}

plain_devnet_bundle() {
    local bundle=$1

    [[ -f "${bundle}/state.json" && ! -L "${bundle}/state.json" \
        && -d "${bundle}/deployments" && ! -L "${bundle}/deployments" \
        && -f "${bundle}/state.fingerprint" \
        && ! -L "${bundle}/state.fingerprint" ]]
}

plain_machine_image() {
    local image=$1
    local manifest=$2

    [[ -d "$image" && ! -L "$image" \
        && -f "$manifest" && ! -L "$manifest" ]]
}

copy_dependency() {
    local name=$1
    local source_path="${source_root}/test/programs/${name}"
    local target_path="${repo_root}/test/programs/${name}"
    local staged_path="${staging_root}/${name}"
    local check_status=0

    if "$dependency_checker" check "$name" "$target_path" >/dev/null 2>&1; then
        return
    else
        check_status=$?
    fi
    if ((check_status != 1)); then
        echo "error: cannot validate target test-program dependency: $name" >&2
        return "$check_status"
    fi

    if "$dependency_checker" check "$name" "$source_path" >/dev/null 2>&1; then
        :
    else
        check_status=$?
        if ((check_status == 1)); then
            echo "source $name is missing or does not match this checkout"
            return
        fi
        echo "error: cannot validate source test-program dependency: $name" >&2
        return "$check_status"
    fi

    cp "$source_path" "$staged_path"
    chmod 0644 "$staged_path"
    "$dependency_checker" check "$name" "$staged_path" >/dev/null
    mv -f -- "$staged_path" "$target_path"
    "$dependency_checker" check "$name" "$target_path" >/dev/null
    echo "copied verified $name"
}

copy_or_build_devnet() {
    local target_bundle="${repo_root}/cartesi-rollups/contracts"
    local source_bundle="${source_root}/cartesi-rollups/contracts"
    local staged_bundle="${staging_root}/devnet"
    local check_status=0

    if plain_devnet_bundle "$target_bundle"; then
        if "$devnet_checker" verify "$target_bundle" >/dev/null 2>&1; then
            echo "kept verified target devnet bundle"
            return
        else
            check_status=$?
        fi
        if ((check_status != 1)); then
            echo "error: cannot validate target devnet bundle" >&2
            return "$check_status"
        fi
    fi

    if ! plain_devnet_bundle "$source_bundle"; then
        echo "source devnet is incomplete or stale; rebuilding"
        just rollups-contracts::build-devnet
        return
    fi
    if "$devnet_checker" verify "$source_bundle" >/dev/null 2>&1; then
        :
    else
        check_status=$?
        if ((check_status == 1)); then
            echo "source devnet is incomplete or stale; rebuilding"
            just rollups-contracts::build-devnet
            return
        fi
        echo "error: cannot validate source devnet bundle" >&2
        return "$check_status"
    fi

    mkdir "$staged_bundle"
    cp "$source_bundle/state.json" "$staged_bundle/state.json"
    cp -R "$source_bundle/deployments" "$staged_bundle/deployments"
    cp "$source_bundle/state.fingerprint" "$staged_bundle/state.fingerprint"
    "$devnet_checker" verify "$staged_bundle" >/dev/null

    if [[ -d "$target_bundle/state.fingerprint" \
        && ! -L "$target_bundle/state.fingerprint" ]]; then
        echo "error: refusing directory at devnet fingerprint target" >&2
        return 2
    fi
    rm -f -- "$target_bundle/state.fingerprint"
    rm -rf -- "$target_bundle/state.json" "$target_bundle/deployments"
    mv "$staged_bundle/state.json" "$target_bundle/state.json"
    mv "$staged_bundle/deployments" "$target_bundle/deployments"
    mv "$staged_bundle/state.fingerprint" "$target_bundle/state.fingerprint"
    rmdir "$staged_bundle"
    "$devnet_checker" verify "$target_bundle" >/dev/null
    echo "copied verified devnet bundle"
}

copy_machine_image() {
    local program=$1
    local relative_image="test/programs/${program}/machine-image"
    local relative_manifest="test/programs/${program}/machine-image.fingerprint"
    local target_image="${repo_root}/${relative_image}"
    local target_manifest="${repo_root}/${relative_manifest}"
    local source_image="${source_root}/${relative_image}"
    local source_manifest="${source_root}/${relative_manifest}"
    local staged_dir="${staging_root}/${program}"
    local staged_image="${staged_dir}/machine-image"
    local staged_manifest="${staged_dir}/machine-image.fingerprint"
    local check_status=0

    if plain_machine_image "$target_image" "$target_manifest"; then
        if "$image_checker" verify "$program" \
            "$target_image" "$target_manifest" >/dev/null 2>&1; then
            echo "kept verified $program machine image"
            return
        else
            check_status=$?
        fi
        if ((check_status != 1)); then
            echo "error: cannot validate target $program machine image" >&2
            return "$check_status"
        fi
    fi

    if ! plain_machine_image "$source_image" "$source_manifest"; then
        echo "source $program machine image is missing, stale, or unverified"
        return
    fi
    if "$image_checker" verify "$program" \
        "$source_image" "$source_manifest" >/dev/null 2>&1; then
        :
    else
        check_status=$?
        if ((check_status == 1)); then
            echo "source $program machine image is missing, stale, or unverified"
            return
        fi
        echo "error: cannot validate source $program machine image" >&2
        return "$check_status"
    fi

    mkdir "$staged_dir"
    cp -R "$source_image" "$staged_image"
    cp "$source_manifest" "$staged_manifest"
    "$image_checker" verify "$program" \
        "$staged_image" "$staged_manifest" >/dev/null

    if [[ -d "$target_manifest" && ! -L "$target_manifest" ]]; then
        echo "error: refusing directory at machine-image fingerprint target: $program" >&2
        return 2
    fi
    rm -f -- "$target_manifest"
    rm -rf -- "$target_image"
    mv "$staged_image" "$target_image"
    mv "$staged_manifest" "$target_manifest"
    rmdir "$staged_dir"
    "$image_checker" verify "$program" \
        "$target_image" "$target_manifest" >/dev/null
    echo "copied verified $program machine image"
}

[[ "$#" -le 1 ]] || usage
source_arg=${1:-}
source_root=

if [[ -n "$source_arg" ]]; then
    if ! source_root="$(CDPATH= cd -- "$source_arg" 2>/dev/null && pwd -P)"; then
        echo "error: cannot resolve SOURCE worktree: $source_arg" >&2
        exit 2
    fi
    if [[ "$source_root" == "$repo_root" ]]; then
        echo "error: SOURCE must be a different worktree" >&2
        exit 2
    fi
fi
readonly source_arg source_root

CDPATH= cd -- "$repo_root" || {
    echo "error: cannot enter the target worktree: $repo_root" >&2
    exit 2
}

just setup
just prt-contracts::install-deps
just rollups-contracts::install-deps
just bind

if [[ -n "$source_root" ]]; then
    require_physical_directory "${repo_root}/test/programs"
    require_physical_directory "${repo_root}/cartesi-rollups/contracts"
    for program in echo yield honeypot; do
        require_physical_directory "${repo_root}/test/programs/${program}"
    done
    for checker in "$dependency_checker" "$devnet_checker" "$image_checker"; do
        if [[ ! -x "$checker" ]]; then
            echo "error: bootstrap checker is missing or not executable: $checker" >&2
            exit 2
        fi
    done
    if ! command -v mktemp >/dev/null; then
        echo "error: mktemp is required to stage bootstrap artifacts" >&2
        exit 2
    fi
    mkdir -p "${repo_root}/target"
    require_physical_directory "${repo_root}/target"
    staging_root="$(mktemp -d "${repo_root}/target/.bootstrap-worktree.XXXXXX")" || {
        echo "error: cannot create the bootstrap staging directory" >&2
        exit 2
    }
    case "$staging_root" in
        "$repo_root"/target/.bootstrap-worktree.*) ;;
        *)
            echo "error: unsafe bootstrap staging directory: $staging_root" >&2
            exit 2
            ;;
    esac
    readonly staging_root
    trap 'rm -rf -- "$staging_root"' EXIT

    copy_dependency linux.bin
    copy_dependency rootfs.ext2
    copy_or_build_devnet
    for program in echo yield honeypot; do
        copy_machine_image "$program"
    done
fi

just doctor
