#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
programs_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"
repo_root="$(CDPATH= cd -- "${programs_dir}/../.." && pwd -P)"
readonly programs_dir repo_root

CDPATH= cd -- "$programs_dir"
"${repo_root}/script/machine-image-fingerprint.sh" capture yield
cartesi-machine --ram-image=./linux.bin --final-hash \
    --flash-drive=label:root,data_filename:./rootfs.ext2 \
    --revert-mode=none --store=./yield/machine-image \
    -- "while true; do yield manual rx-accepted; yield manual rx-rejected; done"
"${repo_root}/script/machine-image-fingerprint.sh" write yield
