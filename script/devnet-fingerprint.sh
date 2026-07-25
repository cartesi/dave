#!/usr/bin/env bash
#
# Record and verify the inputs and outputs of the local devnet bundle.
set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

contract_paths=(cartesi-rollups/contracts prt/contracts)
dependency_paths=(
    cartesi-rollups/contracts/dependencies
    prt/contracts/dependencies
)
config_roots=(
    prt/contracts
    cartesi-rollups/contracts
    cartesi-rollups/contracts/dependencies/cartesi-rollups-contracts-3.0.0-alpha.6
)

usage() {
    cat >&2 <<'EOF'
usage:
  script/devnet-fingerprint.sh
  script/devnet-fingerprint.sh inputs
  script/devnet-fingerprint.sh write EXPECTED_INPUTS [BUNDLE_DIR]
  script/devnet-fingerprint.sh verify [BUNDLE_DIR]
EOF
    exit 2
}

sha256_file() {
    sha256sum -- "$1" | cut -d' ' -f1
}

hash_files() {
    local root=$1
    local path relative file_hash

    if [ ! -d "$root" ]; then
        echo "error: missing fingerprint input directory: $root" >&2
        return 1
    fi

    find "$root" -type f -print0 |
        LC_ALL=C sort -z |
        while IFS= read -r -d '' path; do
            relative=${path#"$root"/}
            file_hash=$(sha256_file "$path")
            printf 'file\0%s\0%s\0' "$relative" "$file_hash"
        done
}

hash_dependency_files() {
    local root=$1
    local path relative file_hash

    if [ ! -d "$root" ]; then
        echo "error: missing fingerprint input directory: $root" >&2
        return 1
    fi

    find "$root" -type f \
        ! -path '*/.git/*' \
        ! -path '*/out/*' \
        ! -path '*/cache/*' \
        ! -path '*/broadcast/*' \
        ! -path '*/deployments/*' \
        -print0 |
        LC_ALL=C sort -z |
        while IFS= read -r -d '' path; do
            relative=${path#"$root"/}
            file_hash=$(sha256_file "$path")
            printf 'file\0%s\0%s\0' "$relative" "$file_hash"
        done
}

hash_contract_files() {
    local path file_hash link_target

    git ls-files --cached --others --exclude-standard -z -- \
        "${contract_paths[@]}" |
        LC_ALL=C sort -zu |
        while IFS= read -r -d '' path; do
            if [ -f "$path" ]; then
                file_hash=$(sha256_file "$path")
                printf 'file\0%s\0%s\0' "$path" "$file_hash"
            elif [ -L "$path" ]; then
                link_target=$(readlink "$path")
                printf 'symlink\0%s\0%s\0' "$path" "$link_target"
            elif [ -e "$path" ]; then
                echo "error: unsupported contract input type: $path" >&2
                return 1
            fi
        done
}

effective_forge_config() {
    local root=$1

    (
        cd "$root"
        forge config --json | jq -Sc '{
            src,
            test,
            script,
            out,
            cache_path,
            libs,
            include_paths,
            allow_paths,
            skip,
            remappings,
            auto_detect_remappings,
            solc,
            auto_detect_solc,
            evm_version,
            optimizer,
            optimizer_runs,
            optimizer_details,
            via_ir,
            bytecode_hash,
            cbor_metadata,
            libraries,
            revert_strings,
            use_literal_content,
            sparse_mode,
            compilation_restrictions,
            additional_compiler_profiles,
            dynamic_test_linking,
            always_use_create_2_factory,
            create2_deployer,
            create2_library_salt,
            celo,
            ffi,
            fs_permissions,
            offline
        }'
    )
}

inputs_digest() {
    local expected_step actual_step forge_path forge_hash forge_version
    local anvil_path anvil_hash anvil_version
    local dependency config_root config_output config_hash step_status

    for tool in anvil forge git jq sha256sum sort; do
        if ! command -v "$tool" >/dev/null; then
            echo "error: $tool is required to fingerprint the devnet" >&2
            return 1
        fi
    done

    expected_step=$(git rev-parse :machine/step)
    if ! actual_step=$(git -C machine/step rev-parse HEAD 2>/dev/null); then
        echo "error: machine/step is not initialized" >&2
        return 1
    fi
    if [ "$actual_step" != "$expected_step" ]; then
        echo "error: machine/step checkout does not match the repository pin" >&2
        echo "fix: git submodule update --init machine/step" >&2
        return 1
    fi
    step_status=$(git -C machine/step status --porcelain --untracked-files=all)
    if [ -n "$step_status" ]; then
        echo "error: machine/step has local changes; submodules are pinned inputs" >&2
        return 1
    fi

    forge_path=$(command -v forge)
    forge_hash=$(sha256_file "$forge_path")
    forge_version=$(forge --version)
    anvil_path=$(command -v anvil)
    anvil_hash=$(sha256_file "$anvil_path")
    anvil_version=$(anvil --version)

    {
        printf 'devnet-inputs-v4\0'
        hash_contract_files || exit 1
        printf 'machine-step\0%s\0' "$actual_step"
        printf 'forge-version\0%s\0forge-binary\0%s\0' \
            "$forge_version" "$forge_hash"
        printf 'anvil-version\0%s\0anvil-binary\0%s\0' \
            "$anvil_version" "$anvil_hash"

        for dependency in "${dependency_paths[@]}"; do
            printf 'dependency-tree\0%s\0' "$dependency"
            hash_dependency_files "$dependency" || exit 1
        done

        for config_root in "${config_roots[@]}"; do
            config_output=$(effective_forge_config "$config_root") || exit 1
            config_hash=$(printf '%s\n' "$config_output" | sha256sum |
                cut -d' ' -f1) || exit 1
            printf 'forge-config\0%s\0%s\0' "$config_root" "$config_hash"
        done
    } | sha256sum | cut -d' ' -f1
}

deployments_digest() {
    local deployments=$1
    local first_file

    if [ ! -d "$deployments" ]; then
        echo "error: missing devnet deployments: $deployments" >&2
        return 1
    fi
    first_file=$(find "$deployments" -type f -print -quit)
    if [ -z "$first_file" ]; then
        echo "error: devnet deployments are empty: $deployments" >&2
        return 1
    fi
    if [ -n "$(find "$deployments" -type l -print -quit)" ]; then
        echo "error: devnet deployments contain a symbolic link" >&2
        return 1
    fi

    {
        printf 'devnet-deployments-v1\0'
        hash_files "$deployments" || exit 1
    } | sha256sum | cut -d' ' -f1
}

read_manifest() {
    local manifest=$1
    local record

    if [ ! -f "$manifest" ]; then
        echo "error: missing devnet fingerprint: $manifest" >&2
        return 1
    fi
    record=$(cat -- "$manifest")
    if [[ ! "$record" =~ ^v3[[:space:]]([0-9a-f]{64})[[:space:]]([0-9a-f]{64})[[:space:]]([0-9a-f]{64})$ ]]; then
        echo "error: malformed devnet fingerprint: $manifest" >&2
        return 1
    fi

    recorded_inputs=${BASH_REMATCH[1]}
    recorded_state=${BASH_REMATCH[2]}
    recorded_deployments=${BASH_REMATCH[3]}
}

mode=${1:-inputs}

case "$mode" in
    inputs)
        [ "$#" -le 1 ] || usage
        inputs_digest
        ;;
    write)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
        expected_inputs=$2
        bundle=${3:-cartesi-rollups/contracts}
        [[ "$expected_inputs" =~ ^[0-9a-f]{64}$ ]] || usage

        current_inputs=$(inputs_digest)
        if [ "$current_inputs" != "$expected_inputs" ]; then
            echo "error: devnet inputs changed during deployment" >&2
            exit 1
        fi
        if [ ! -s "$bundle/state.json" ]; then
            echo "error: missing devnet state: $bundle/state.json" >&2
            exit 1
        fi
        state_hash=$(sha256_file "$bundle/state.json")
        deployment_hash=$(deployments_digest "$bundle/deployments")
        pending="$bundle/state.fingerprint.pending"
        manifest="$bundle/state.fingerprint"
        printf 'v3 %s %s %s\n' \
            "$current_inputs" "$state_hash" "$deployment_hash" > "$pending"
        mv -- "$pending" "$manifest"
        echo "devnet fingerprint: $manifest"
        ;;
    verify)
        [ "$#" -le 2 ] || usage
        bundle=${2:-cartesi-rollups/contracts}
        read_manifest "$bundle/state.fingerprint"
        current_inputs=$(inputs_digest)
        if [ ! -s "$bundle/state.json" ]; then
            echo "error: missing devnet state: $bundle/state.json" >&2
            exit 1
        fi
        current_state=$(sha256_file "$bundle/state.json")
        current_deployments=$(deployments_digest "$bundle/deployments")

        if [ "$recorded_inputs" != "$current_inputs" ]; then
            echo "error: devnet inputs changed" >&2
            exit 1
        fi
        if [ "$recorded_state" != "$current_state" ]; then
            echo "error: devnet state changed" >&2
            exit 1
        fi
        if [ "$recorded_deployments" != "$current_deployments" ]; then
            echo "error: devnet deployments changed" >&2
            exit 1
        fi
        echo "devnet bundle verified"
        ;;
    *)
        usage
        ;;
esac
