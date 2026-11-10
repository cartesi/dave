#!/usr/bin/env bash
# Put the pinned solc where Foundry looks for installed compilers, on the one
# platform its installer cannot serve.
#
# The pinned Foundry embeds svm-rs 0.5.22, which takes Linux arm64 builds
# from a community list frozen at solc 0.8.30. Solidity has published
# official Linux arm64 builds since 0.8.31, and Foundry uses a pinned
# compiler it finds installed without asking svm to download it. Every
# other platform is served by svm and is left alone.
#
# Delete this script, its recipe and its callers once FOUNDRY_VERSION moves
# to a release whose svm reads the official Linux arm64 list.
set -euo pipefail

usage() {
    printf 'usage: script/solc-linux-arm64.sh install|verify\n' >&2
    exit 2
}

(($# == 1)) || usage
case "$1" in install | verify) ;; *) usage ;; esac
readonly action=$1
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="${script_dir%/script}"

# The build named by https://binaries.soliditylang.org/linux-arm64/list.json
# for this version, with the SHA-256 it lists.
readonly version=0.8.38
readonly build="solc-linux-arm64-v${version}+commit.1835d247"
readonly sha256=7a986c8f85945fec780d2cbb352cdd85959b7222dd33830a7563c2af4bc1fca0
readonly url="https://binaries.soliditylang.org/linux-arm64/${build}"

# A compiler bump must move this pin with it, on every platform, or the
# Linux arm64 build would be the only place to notice.
for project in prt/contracts cartesi-rollups/contracts; do
    pinned="$(sed -n 's/^solc_version = "\(.*\)"$/\1/p' "${repo_root}/${project}/foundry.toml")"
    if [[ "$pinned" != "$version" ]]; then
        printf 'error: %s/foundry.toml pins solc %s, script/solc-linux-arm64.sh installs %s; update its version, build and sha256 from https://binaries.soliditylang.org/linux-arm64/list.json\n' \
            "$project" "${pinned:-nothing}" "$version" >&2
        exit 2
    fi
done

case "$(uname -s)/$(uname -m)" in
    Linux/aarch64) ;;
    *)
        printf 'solc: Foundry installs solc %s itself on this platform\n' "$version"
        exit 0
        ;;
esac

# svm-rs keeps compilers in ~/.svm when that exists or when the XDG data
# directory does not, and in the XDG data directory otherwise.
data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
if [[ ! -e "${HOME}/.svm" && -e "$data_home" ]]; then
    svm_dir="${data_home}/svm"
else
    svm_dir="${HOME}/.svm"
fi
readonly dest="${svm_dir}/${version}/solc-${version}"

if [[ "$action" == verify ]]; then
    digest="$(sha256sum -- "$dest" 2>/dev/null)" || digest=
    if [[ -x "$dest" && "${digest%% *}" == "$sha256" ]]; then
        printf 'solc: %s is installed for Foundry\n' "$version"
        exit 0
    fi
    printf 'error: solc %s is not installed at %s, and Foundry cannot download it on Linux arm64\n' \
        "$version" "$dest" >&2
    exit 1
fi

"${repo_root}/script/fetch.sh" "$url" "$sha256" "$dest"
chmod 0755 "$dest"
# The file is the pinned bytes; this checks that they run here.
reported="$("$dest" --version 2>&1)" || reported=
if [[ "$reported" != *"Version: ${version}+"* ]]; then
    printf 'error: %s does not run as solc %s on this machine\n' "$dest" "$version" >&2
    exit 1
fi
printf 'solc: installed %s at %s\n' "$version" "$dest"
