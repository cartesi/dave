#!/usr/bin/env bash
# Record and verify the production inputs and outputs of the local devnet bundle.
set -u
set -o pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'error: cannot resolve the devnet fingerprint script directory\n' >&2
    exit 2
}
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    printf 'error: cannot resolve the repository root\n' >&2
    exit 2
}
readonly script_dir repo_root
CDPATH= cd -- "$repo_root" || {
    printf 'error: cannot enter the repository root: %s\n' "$repo_root" >&2
    exit 2
}

readonly base_contracts="cartesi-rollups/contracts/dependencies/cartesi-rollups-contracts-3.0.0-alpha.10"
readonly input_format="devnet-inputs-v5"
readonly manifest_format="v4"

source_roots=(
    prt/contracts/src
    prt/contracts/dependencies
    cartesi-rollups/contracts/src
    cartesi-rollups/contracts/dependencies
    machine/step/src
)
config_roots=(
    prt/contracts
    cartesi-rollups/contracts
    "$base_contracts"
)
deployment_files=(
    prt/contracts/soldeer.lock
    prt/contracts/script/BaseDeploymentScript.sol
    prt/contracts/script/Deployment.s.sol
    cartesi-rollups/contracts/soldeer.lock
    cartesi-rollups/contracts/script/Deployment.s.sol
    cartesi-rollups/contracts/script/build-devnet.sh
    cartesi-rollups/contracts/script/deploy.sh
)

usage() {
    cat >&2 <<'EOF'
usage:
  script/devnet-fingerprint.sh
  script/devnet-fingerprint.sh inputs
  script/devnet-fingerprint.sh write EXPECTED_INPUTS [BUNDLE_DIR]
  script/devnet-fingerprint.sh verify [BUNDLE_DIR]

Exit status: 0 is healthy, 1 is missing or stale, and 2 means the checker
could not determine the result.
EOF
    exit 2
}

stale() {
    printf 'error: %s\n' "$1" >&2
    return 1
}

checker_error() {
    printf 'error: %s\n' "$1" >&2
    return 2
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        checker_error "$1 is required to fingerprint the devnet"
        return 2
    }
}

sha256_file() {
    local path=$1
    local output=""

    if ! output="$(sha256sum -- "$path" 2>&1)"; then
        checker_error "cannot hash ${path}: ${output##*$'\n'}"
        return 2
    fi
    printf '%s\n' "${output%% *}"
}

effective_forge_config() {
    local root=$1
    local raw="" canonical=""

    if [[ ! -d "$root" || -L "$root" ]]; then
        stale "missing Forge project used by the devnet: ${root}"
        return 1
    fi
    if ! raw="$(CDPATH= cd -- "$root" && forge config --json 2>&1)"; then
        checker_error "cannot read the effective Forge configuration for ${root}: ${raw##*$'\n'}"
        return 2
    fi
    if ! canonical="$(
        printf '%s\n' "$raw" | jq -cS '
            {
                additional_compiler_profiles,
                allow_paths,
                always_use_create_2_factory,
                auto_detect_remappings,
                auto_detect_solc,
                block_base_fee_per_gas,
                block_coinbase,
                block_difficulty,
                block_gas_limit,
                block_number,
                block_prevrandao,
                block_timestamp,
                bytecode_hash,
                cbor_metadata,
                cache_path,
                celo,
                chain_id,
                compilation_restrictions,
                create2_deployer,
                create2_library_salt,
                dependencies,
                dynamic_test_linking,
                evm_version,
                extra_args,
                extra_output,
                extra_output_files,
                ffi,
                fs_permissions,
                gas_limit,
                gas_price,
                include_paths,
                libraries,
                libs,
                offline,
                optimizer,
                optimizer_details,
                optimizer_runs,
                out,
                remappings,
                revert_strings,
                script,
                script_execution_protection,
                sender,
                skip,
                solc,
                soldeer,
                sparse_mode,
                src,
                test,
                tx_origin,
                use_literal_content,
                via_ir
            }
        ' 2>&1
    )"; then
        checker_error "cannot canonicalize the Forge configuration for ${root}: ${canonical##*$'\n'}"
        return 2
    fi
    printf '%s\n' "$canonical"
}

inputs_digest() (
    local manifest="" digest="" root="" path="" config="" version=""
    local first="" rc=0

    for tool in anvil find forge jq mktemp sha256sum sort xargs; do
        require_tool "$tool" || return $?
    done
    for root in "${source_roots[@]}" "${config_roots[@]}"; do
        if [[ ! -d "$root" || -L "$root" ]]; then
            stale "missing devnet source or configuration root: ${root}"
            return 1
        fi
    done
    for path in "${deployment_files[@]}"; do
        if [[ ! -f "$path" || -L "$path" ]]; then
            stale "missing regular devnet input: ${path}"
            return 1
        fi
    done

    if ! manifest="$(mktemp "${TMPDIR:-/tmp}/dave-devnet-inputs.XXXXXX" 2>/dev/null)"; then
        checker_error "cannot create the devnet input manifest"
        return 2
    fi
    trap 'rm -f -- "$manifest"' EXIT
    if ! printf '%s\0' "$input_format" >"$manifest"; then
        checker_error "cannot initialize the devnet input manifest"
        return 2
    fi

    for path in "${deployment_files[@]}"; do
        digest="$(sha256_file "$path")" || return $?
        printf 'file\0%s\0%s\0' "$path" "$digest" >>"$manifest" || {
            checker_error "cannot write the devnet input manifest"
            return 2
        }
    done

    # This is the deployment source set: production and deployment Solidity,
    # not neighboring tests, docs, compiler output, or old deployment records.
    first="$(find "${source_roots[@]}" -type f -name '*.sol' \
        ! -path '*/test/*' ! -path '*/tests/*' \
        ! -path '*/out/*' ! -path '*/cache/*' \
        ! -path '*/broadcast/*' ! -path '*/deployments/*' \
        -print -quit 2>&1)"
    rc=$?
    if ((rc != 0)); then
        checker_error "cannot enumerate the devnet Solidity inputs: ${first##*$'\n'}"
        return 2
    elif [[ -z "$first" ]]; then
        stale "the devnet production source set is empty"
        return 1
    fi
    printf 'solidity-sources\0' >>"$manifest"
    find "${source_roots[@]}" -type f -name '*.sol' \
        ! -path '*/test/*' ! -path '*/tests/*' \
        ! -path '*/out/*' ! -path '*/cache/*' \
        ! -path '*/broadcast/*' ! -path '*/deployments/*' \
        -print0 2>/dev/null | LC_ALL=C sort -z \
        | xargs -0 sha256sum -- >>"$manifest"
    rc=$?
    if ((rc != 0)); then
        checker_error "cannot hash the devnet Solidity inputs"
        return 2
    fi

    for root in "${config_roots[@]}"; do
        config="$(effective_forge_config "$root")" || return $?
        printf 'forge-config\0%s\0%s\0' "$root" "$config" >>"$manifest" || {
            checker_error "cannot write the devnet input manifest"
            return 2
        }
    done
    for path in forge anvil; do
        if ! version="$("$path" --version 2>&1)"; then
            checker_error "cannot inspect ${path}: ${version##*$'\n'}"
            return 2
        elif [[ -z "$version" ]]; then
            checker_error "${path} --version produced no output"
            return 2
        fi
        printf 'tool-version\0%s\0%s\0' "$path" "$version" >>"$manifest" || {
            checker_error "cannot write the devnet input manifest"
            return 2
        }
    done

    digest="$(sha256_file "$manifest")" || return $?
    printf '%s\n' "$digest"
)

tree_digest() (
    local root=$1
    local domain=$2
    local manifest="" digest="" link="" first=""
    local rc=0

    if [[ ! -d "$root" || -L "$root" ]]; then
        stale "missing devnet deployments: ${root}"
        return 1
    fi
    if ! link="$(find "$root" -type l -print -quit 2>&1)"; then
        checker_error "cannot inspect devnet deployments: ${link##*$'\n'}"
        return 2
    fi
    if [[ -n "$link" ]]; then
        stale "devnet deployments contain a symbolic link: ${link}"
        return 1
    fi

    if ! manifest="$(mktemp "${TMPDIR:-/tmp}/dave-devnet-tree.XXXXXX" 2>/dev/null)"; then
        checker_error "cannot create the devnet deployments manifest"
        return 2
    fi
    trap 'rm -f -- "$manifest"' EXIT
    first="$(find "$root" -type f -print -quit 2>&1)"
    rc=$?
    if ((rc != 0)); then
        checker_error "cannot enumerate devnet deployments: ${root}"
        return 2
    fi
    if [[ -z "$first" ]]; then
        stale "devnet deployments are empty: ${root}"
        return 1
    fi
    if ! printf '%s\0' "$domain" >"$manifest"; then
        checker_error "cannot initialize the devnet deployments manifest"
        return 2
    fi
    (
        CDPATH= cd -- "$root" || exit 2
        find . -type f -print0 2>/dev/null | LC_ALL=C sort -z \
            | xargs -0 sha256sum --
    ) >>"$manifest"
    rc=$?
    if ((rc != 0)); then
        checker_error "cannot hash devnet deployments: ${root}"
        return 2
    fi
    digest="$(sha256_file "$manifest")" || return $?
    printf '%s\n' "$digest"
)

read_manifest() {
    local manifest=$1
    local record=""

    if [[ ! -f "$manifest" || -L "$manifest" ]]; then
        stale "missing regular devnet fingerprint: ${manifest}"
        return 1
    fi
    if ! record="$(cat -- "$manifest" 2>&1)"; then
        checker_error "cannot read devnet fingerprint ${manifest}: ${record##*$'\n'}"
        return 2
    fi
    if [[ ! "$record" =~ ^${manifest_format}[[:space:]]([0-9a-f]{64})[[:space:]]([0-9a-f]{64})[[:space:]]([0-9a-f]{64})$ ]]; then
        stale "malformed or obsolete devnet fingerprint: ${manifest}"
        return 1
    fi

    recorded_inputs=${BASH_REMATCH[1]}
    recorded_state=${BASH_REMATCH[2]}
    recorded_deployments=${BASH_REMATCH[3]}
}

require_state() {
    local state=$1

    if [[ ! -s "$state" || -L "$state" ]]; then
        stale "missing regular nonempty devnet state: ${state}"
        return 1
    fi
}

mode=${1:-inputs}
case "$mode" in
    inputs)
        [[ "$#" -le 1 ]] || usage
        inputs_digest
        exit $?
        ;;
    write)
        [[ "$#" -ge 2 && "$#" -le 3 ]] || usage
        expected_inputs=$2
        bundle=${3:-cartesi-rollups/contracts}
        [[ "$expected_inputs" =~ ^[0-9a-f]{64}$ ]] || usage

        current_inputs="$(inputs_digest)" || exit $?
        if [[ "$current_inputs" != "$expected_inputs" ]]; then
            stale "devnet inputs changed during deployment"
            exit 1
        fi
        require_state "$bundle/state.json" || exit $?
        state_hash="$(sha256_file "$bundle/state.json")" || exit $?
        deployment_hash="$(tree_digest "$bundle/deployments" devnet-deployments-v2)" \
            || exit $?
        pending="$bundle/state.fingerprint.pending"
        manifest="$bundle/state.fingerprint"
        if ! printf '%s %s %s %s\n' "$manifest_format" "$current_inputs" \
            "$state_hash" "$deployment_hash" >"$pending"; then
            checker_error "cannot write pending devnet fingerprint: ${pending}"
            exit 2
        fi
        if ! mv -f -- "$pending" "$manifest"; then
            checker_error "cannot publish devnet fingerprint: ${manifest}"
            exit 2
        fi
        printf 'devnet fingerprint: %s\n' "$manifest"
        ;;
    verify)
        [[ "$#" -le 2 ]] || usage
        bundle=${2:-cartesi-rollups/contracts}
        read_manifest "$bundle/state.fingerprint" || exit $?
        current_inputs="$(inputs_digest)" || exit $?
        require_state "$bundle/state.json" || exit $?
        current_state="$(sha256_file "$bundle/state.json")" || exit $?
        current_deployments="$(tree_digest "$bundle/deployments" devnet-deployments-v2)" \
            || exit $?

        if [[ "$recorded_inputs" != "$current_inputs" ]]; then
            stale "devnet production or deployment inputs changed"
            exit 1
        fi
        if [[ "$recorded_state" != "$current_state" ]]; then
            stale "devnet state changed"
            exit 1
        fi
        if [[ "$recorded_deployments" != "$current_deployments" ]]; then
            stale "devnet deployments changed"
            exit 1
        fi
        printf 'devnet bundle verified\n'
        ;;
    *) usage ;;
esac
