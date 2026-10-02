#!/usr/bin/env bash
# The SHA-pinned release kernel and rootfs every test program image boots.
set -euo pipefail

programs_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly programs_dir fetch="${programs_dir}/../../script/fetch.sh"

usage() {
    cat >&2 <<'EOF'
usage:
  script/download-deps.sh check NAME [PATH]
  script/download-deps.sh download

NAME is linux.bin or rootfs.ext2. PATH defaults to test/programs/NAME.
EOF
    exit 2
}

pin() {
    case "$1" in
        linux.bin)
            url="https://github.com/cartesi/image-kernel/releases/download/v0.21.0/linux-6.5.13-ctsi-2-v0.21.0.bin"
            sha="5c900060da2db2bfa84cd39cd9cd722988c83c42225f3cac55f2d3157e48f32f"
            ;;
        rootfs.ext2)
            url="https://github.com/cartesi/machine-emulator-tools/releases/download/v0.18.0/rootfs-tools.ext2"
            sha="6c159937485c99f695021c4f2ea2a57bdadcf4e4bce8e71af5bee3bb9552802e"
            ;;
        *) usage ;;
    esac
}

case "${1:-}" in
    download)
        (($# == 1)) || usage
        for name in linux.bin rootfs.ext2; do
            pin "$name"
            "$fetch" "$url" "$sha" "${programs_dir}/${name}"
        done
        ;;
    check)
        (($# == 2 || $# == 3)) || usage
        pin "$2"
        path=${3:-"${programs_dir}/$2"}
        digest="$(sha256sum -- "$path" 2>/dev/null)" || digest=""
        if [[ "${digest%% *}" != "$sha" ]]; then
            printf 'error: test-program dependency is missing or does not match its pin: %s\n' \
                "$path" >&2
            exit 1
        fi
        ;;
    *) usage ;;
esac
