#!/usr/bin/env bash
#
# Record and verify the inputs and semantic root of a test machine image.
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    echo "error: cannot resolve the machine-image fingerprint script directory" >&2
    exit 2
}
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    echo "error: cannot resolve the repository root" >&2
    exit 2
}
readonly script_dir repo_root
CDPATH= cd -- "$repo_root" || {
    echo "error: cannot enter the repository root: $repo_root" >&2
    exit 2
}

usage() {
    cat >&2 <<'EOF'
usage:
  script/machine-image-fingerprint.sh inputs PROGRAM
  script/machine-image-fingerprint.sh capture PROGRAM [MANIFEST]
  script/machine-image-fingerprint.sh write PROGRAM [IMAGE [MANIFEST]]
  script/machine-image-fingerprint.sh verify PROGRAM [IMAGE [MANIFEST]]
EOF
    exit 2
}

sha256_file() {
    local output=""

    if output="$(sha256sum -- "$1" 2>&1)"; then
        printf '%s\n' "${output%% *}"
    else
        echo "error: cannot hash $1: ${output##*$'\n'}" >&2
        return 2
    fi
}

producer_script() {
    case "$1" in
        echo) printf '%s\n' test/programs/script/build-echo.sh ;;
        yield) printf '%s\n' test/programs/script/build-yield.sh ;;
        stress) printf '%s\n' test/programs/script/build-stress.sh ;;
        honeypot) printf '%s\n' test/programs/script/build-honeypot.sh ;;
        *) return 2 ;;
    esac
}

deployment_address() {
    local contract_name=$1
    local deployment="cartesi-rollups/contracts/deployments/31337/${contract_name}.txt"

    if [ ! -f "$deployment" ]; then
        echo "error: missing devnet deployment: $deployment" >&2
        return 1
    fi
    cat "$deployment"
}

inputs_digest() {
    local program=$1
    local machine_version machine_path machine_hash emulator_pin git_emulator_pin
    local provided_emulator_pin producer producer_hash
    local generator_hash portal_address token_address linux_hash rootfs_hash

    case "$program" in
        echo|yield|stress|honeypot) ;;
        *)
            echo "error: unsupported test program: $program" >&2
            return 2
            ;;
    esac

    for tool in cartesi-machine sha256sum; do
        if ! command -v "$tool" >/dev/null; then
            echo "error: $tool is required to fingerprint machine images" >&2
            return 2
        fi
    done

    if ! machine_version=$(cartesi-machine --version 2>&1); then
        echo "error: cannot inspect cartesi-machine: ${machine_version##*$'\n'}" >&2
        return 2
    fi
    machine_version="${machine_version%%$'\n'*}"
    machine_path=$(command -v cartesi-machine)
    machine_hash=$(sha256_file "$machine_path") || return $?
    provided_emulator_pin=${DAVE_EMULATOR_GITLINK:-}
    if [ -n "$provided_emulator_pin" ] \
        && [[ ! "$provided_emulator_pin" =~ ^[0-9a-f]{40}$ ]]; then
        echo "error: invalid DAVE_EMULATOR_GITLINK: $provided_emulator_pin" >&2
        return 2
    fi
    if git_emulator_pin=$(git rev-parse :machine/emulator 2>/dev/null); then
        if [[ ! "$git_emulator_pin" =~ ^[0-9a-f]{40}$ ]]; then
            echo "error: invalid emulator gitlink in the Git index: $git_emulator_pin" >&2
            return 2
        fi
        if [ -n "$provided_emulator_pin" ] \
            && [ "$provided_emulator_pin" != "$git_emulator_pin" ]; then
            echo "error: DAVE_EMULATOR_GITLINK does not match the Git index" >&2
            return 2
        fi
        emulator_pin=$git_emulator_pin
    elif [ -n "$provided_emulator_pin" ]; then
        emulator_pin=$provided_emulator_pin
    else
        echo "error: cannot resolve the emulator gitlink from Git or the environment" >&2
        return 2
    fi
    producer=$(producer_script "$program") || {
        echo "error: no producer is registered for test program: $program" >&2
        return 2
    }
    if [[ ! -f "$producer" || -L "$producer" ]]; then
        echo "error: invalid machine-image producer: $producer" >&2
        return 2
    fi
    producer_hash=$(sha256_file "$producer") || return $?

    if [ "$program" = honeypot ]; then
        if ! command -v jq >/dev/null; then
            echo "error: jq is required to fingerprint the Honeypot image" >&2
            return 2
        fi
        generator_hash=$(sha256_file \
            test/programs/honeypot/generate-devnet-honeypot-config.sh) || return $?
        portal_address=$(deployment_address Erc20Portal) || return 1
        token_address=$(deployment_address TestFungibleToken) || return 1
    else
        for input in linux.bin rootfs.ext2; do
            if [ ! -f "test/programs/$input" ]; then
                echo "error: missing machine-image input: test/programs/$input" >&2
                return 1
            fi
        done
        linux_hash=$(sha256_file test/programs/linux.bin) || return $?
        rootfs_hash=$(sha256_file test/programs/rootfs.ext2) || return $?
    fi

    {
        printf 'machine-image-inputs-v2\n'
        printf 'program=%s\n' "$program"
        printf 'producer=%s\n' "$producer"
        printf 'producer-sha256=%s\n' "$producer_hash"
        printf 'cartesi-machine=%s\n' "$machine_version"
        printf 'cartesi-machine-binary=%s\n' "$machine_hash"
        printf 'emulator-gitlink=%s\n' "$emulator_pin"

        if [ "$program" = honeypot ]; then
            printf 'honeypot-config-generator=%s\n' "$generator_hash"
            printf 'erc20-portal=%s\n' "$portal_address"
            printf 'test-fungible-token=%s\n' "$token_address"
        else
            printf 'linux.bin=%s\n' "$linux_hash"
            printf 'rootfs.ext2=%s\n' "$rootfs_hash"
        fi
    } | sha256sum | cut -d' ' -f1
}

read_manifest() {
    local manifest=$1
    local record

    if [ ! -f "$manifest" ]; then
        echo "error: missing machine-image fingerprint: $manifest" >&2
        return 1
    fi
    record=$(cat -- "$manifest")
    if [[ ! "$record" =~ ^v2[[:space:]]([A-Za-z0-9._-]+)[[:space:]]([0-9a-f]{64})[[:space:]]([0-9a-f]{64})$ ]]; then
        echo "error: malformed machine-image fingerprint: $manifest" >&2
        return 1
    fi

    recorded_program=${BASH_REMATCH[1]}
    recorded_inputs=${BASH_REMATCH[2]}
    recorded_root=${BASH_REMATCH[3]}
}

mode=${1:-}
program=${2:-}
[ -n "$mode" ] && [ -n "$program" ] || usage
[[ "$program" =~ ^[A-Za-z0-9._-]+$ ]] || usage

image=${3:-"test/programs/$program/machine-image"}
manifest=${4:-"test/programs/$program/machine-image.fingerprint"}
pending="${manifest}.pending"

case "$mode" in
    inputs)
        [ "$#" -eq 2 ] || usage
        inputs_digest "$program"
        ;;
    capture)
        [ "$#" -le 3 ] || usage
        manifest=${3:-"test/programs/$program/machine-image.fingerprint"}
        pending="${manifest}.pending"
        mkdir -p "$(dirname "$manifest")"
        inputs=$(inputs_digest "$program")
        printf '%s\n' "$inputs" > "$pending"
        echo "captured machine-image inputs: $program"
        ;;
    write)
        [ "$#" -le 4 ] || usage
        if [ ! -d "$image" ]; then
            echo "error: missing machine image: $image" >&2
            exit 1
        fi
        for tool in cartesi-machine-stored-hash mktemp; do
            if ! command -v "$tool" >/dev/null; then
                echo "error: $tool is required to fingerprint machine images" >&2
                exit 1
            fi
        done
        if [ ! -f "$pending" ]; then
            echo "error: missing pre-build input capture: $pending" >&2
            echo "fix: run the capture mode before constructing the image" >&2
            exit 1
        fi
        expected_inputs=$(cat -- "$pending")
        if [[ ! "$expected_inputs" =~ ^[0-9a-f]{64}$ ]]; then
            echo "error: malformed pre-build input capture: $pending" >&2
            exit 1
        fi
        inputs=$(inputs_digest "$program")
        if [ "$inputs" != "$expected_inputs" ]; then
            echo "error: machine-image inputs changed while building $program" >&2
            exit 1
        fi
        root=$(cartesi-machine-stored-hash "$image")
        root=${root#0x}
        [[ "$root" =~ ^[0-9a-f]{64}$ ]] || {
            echo "error: invalid stored machine root for $image: $root" >&2
            exit 1
        }
        mkdir -p "$(dirname "$manifest")"
        temporary=$(mktemp "${manifest}.tmp.XXXXXX")
        trap 'rm -f -- "$temporary"' EXIT
        printf 'v2 %s %s %s\n' "$program" "$inputs" "$root" > "$temporary"
        mv -- "$temporary" "$manifest"
        trap - EXIT
        rm -f -- "$pending"
        echo "machine image fingerprint: $manifest"
        ;;
    verify)
        [ "$#" -le 4 ] || usage
        if [ ! -d "$image" ]; then
            echo "error: missing machine image: $image" >&2
            exit 1
        fi
        if ! command -v cartesi-machine-stored-hash >/dev/null; then
            echo "error: cartesi-machine-stored-hash is required to verify machine images" >&2
            exit 2
        fi
        read_manifest "$manifest"
        current_inputs=$(inputs_digest "$program")
        current_root=$(cartesi-machine-stored-hash "$image") || {
            echo "error: cannot calculate the stored machine root for $image" >&2
            exit 1
        }
        current_root=${current_root#0x}
        [[ "$current_root" =~ ^[0-9a-f]{64}$ ]] || {
            echo "error: invalid stored machine root for $image: $current_root" >&2
            exit 1
        }
        if [ "$recorded_program" != "$program" ]; then
            echo "error: fingerprint program is $recorded_program, expected $program" >&2
            exit 1
        fi
        if [ "$recorded_inputs" != "$current_inputs" ]; then
            echo "error: machine-image inputs changed for $program" >&2
            exit 1
        fi
        if [ "$recorded_root" != "$current_root" ]; then
            echo "error: machine-image root changed for $program" >&2
            exit 1
        fi
        echo "machine image verified: $program"
        ;;
    *)
        usage
        ;;
esac
