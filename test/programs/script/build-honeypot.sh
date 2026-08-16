#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
programs_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"
repo_root="$(CDPATH= cd -- "${programs_dir}/../.." && pwd -P)"
readonly programs_dir repo_root

CDPATH= cd -- "$programs_dir"
"${repo_root}/script/machine-image-fingerprint.sh" capture honeypot
git clone https://github.com/cartesi/honeypot.git honeypot/project
git -C honeypot/project reset --hard 23b31c06f0537cbd33f996f4ecf1ef6bea8363b3 # cartesi/honeypot#37
mkdir -p honeypot/project/config/devnet
./honeypot/generate-devnet-honeypot-config.sh \
    > honeypot/project/config/devnet/honeypot-config.hpp
make -C honeypot/project snapshot HONEYPOT_CONFIG=devnet
cp -r honeypot/project/snapshot honeypot/machine-image
"${repo_root}/script/machine-image-fingerprint.sh" write honeypot
