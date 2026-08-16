#!/usr/bin/env bash
set -u

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'error: cannot resolve the dependency script directory\n' >&2
    exit 2
}
programs_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    printf 'error: cannot resolve the programs directory\n' >&2
    exit 2
}
readonly script_dir programs_dir

temporary=""
trap 'if [[ -n "$temporary" ]]; then rm -f -- "$temporary"; fi' EXIT

usage() {
    cat >&2 <<'EOF'
usage:
  script/download-deps.sh check NAME [PATH]
  script/download-deps.sh download

NAME is linux.bin or rootfs.ext2. PATH defaults to test/programs/NAME.
EOF
    exit 2
}

asset_fields() {
    case "$1" in
        linux.bin)
            asset_url="https://github.com/cartesi/image-kernel/releases/download/v0.21.0/linux-6.5.13-ctsi-2-v0.21.0.bin"
            asset_sha256="5c900060da2db2bfa84cd39cd9cd722988c83c42225f3cac55f2d3157e48f32f"
            ;;
        rootfs.ext2)
            asset_url="https://github.com/cartesi/machine-emulator-tools/releases/download/v0.18.0/rootfs-tools.ext2"
            asset_sha256="6c159937485c99f695021c4f2ea2a57bdadcf4e4bce8e71af5bee3bb9552802e"
            ;;
        *)
            printf 'error: unsupported test-program dependency: %s\n' "$1" >&2
            return 2
            ;;
    esac
}

file_digest() {
    local path=$1
    local output=""

    if output="$(sha256sum -- "$path" 2>&1)"; then
        printf '%s\n' "${output%% *}"
    else
        printf 'error: cannot hash %s: %s\n' "$path" "${output##*$'\n'}" >&2
        return 2
    fi
}

check_asset() {
    local name=$1
    local target=${2:-"${programs_dir}/${name}"}
    local actual=""

    asset_fields "$name" || return $?
    if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
        printf 'error: test-program dependency is not a regular non-symlink file: %s\n' \
            "$target" >&2
        return 2
    fi
    if [[ ! -f "$target" ]]; then
        printf 'error: missing test-program dependency: %s\n' "$target" >&2
        return 1
    fi
    actual="$(file_digest "$target")" || return $?
    if [[ "$actual" != "$asset_sha256" ]]; then
        printf 'error: test-program dependency checksum mismatch: %s\n' "$target" >&2
        return 1
    fi
}

download_asset() {
    local name=$1
    local actual="" operation_status=0 target=""

    asset_fields "$name" || return $?
    target="${programs_dir}/${name}"
    if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
        printf 'error: refusing unsafe test-program dependency target: %s\n' \
            "$target" >&2
        return 2
    fi
    if [[ -f "$target" ]]; then
        actual="$(file_digest "$target")" || return $?
        if [[ "$actual" == "$asset_sha256" ]]; then
            printf 'test-program dependency cached: %s\n' "$name"
            return 0
        fi
    fi

    if ! command -v wget >/dev/null; then
        printf 'error: wget is required to download test-program dependencies\n' >&2
        return 2
    fi
    if ! command -v mktemp >/dev/null; then
        printf 'error: mktemp is required to download test-program dependencies\n' >&2
        return 2
    fi
    if ! temporary="$(mktemp "${programs_dir}/.${name}.tmp.XXXXXX")"; then
        printf 'error: cannot create a temporary download beside %s\n' "$target" >&2
        return 2
    fi
    if ! wget -O "$temporary" "$asset_url"; then
        printf 'error: failed to download %s\n' "$asset_url" >&2
        rm -f -- "$temporary"
        temporary=""
        return 1
    fi
    actual="$(file_digest "$temporary")" || {
        operation_status=$?
        rm -f -- "$temporary"
        temporary=""
        return "$operation_status"
    }
    if [[ "$actual" != "$asset_sha256" ]]; then
        printf 'error: downloaded dependency checksum mismatch: %s\n' "$name" >&2
        rm -f -- "$temporary"
        temporary=""
        return 1
    fi
    if ! chmod 0644 "$temporary"; then
        printf 'error: cannot set test-program dependency permissions: %s\n' \
            "$temporary" >&2
        rm -f -- "$temporary"
        temporary=""
        return 2
    fi
    if ! mv -f -- "$temporary" "$target"; then
        printf 'error: cannot publish test-program dependency: %s\n' "$target" >&2
        rm -f -- "$temporary"
        temporary=""
        return 2
    fi
    temporary=""
    printf 'test-program dependency downloaded: %s\n' "$name"
}

for required_tool in sha256sum; do
    if ! command -v "$required_tool" >/dev/null; then
        printf 'error: %s is required to manage test-program dependencies\n' \
            "$required_tool" >&2
        exit 2
    fi
done

mode=${1:-}
case "$mode" in
    check)
        [[ "$#" -ge 2 && "$#" -le 3 ]] || usage
        check_asset "$2" "${3:-}"
        ;;
    download)
        [[ "$#" -eq 1 ]] || usage
        status=0
        for asset_name in linux.bin rootfs.ext2; do
            download_asset "$asset_name"
            asset_status=$?
            if ((asset_status > status)); then
                status=$asset_status
            fi
        done
        exit "$status"
        ;;
    *)
        usage
        ;;
esac
