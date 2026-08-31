#!/usr/bin/env bash
set -u
set -o pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf 'error: cannot resolve the binding script directory\n' >&2
    exit 2
}
repo_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)" || {
    printf 'error: cannot resolve the repository root\n' >&2
    exit 2
}
readonly script_dir repo_dir
readonly script_path="${script_dir}/$(basename -- "${BASH_SOURCE[0]}")"
readonly disabled_test_root=".dave-bindings-no-tests"
readonly disabled_script_root=".dave-bindings-no-scripts"

temp_dir=""
module_name=""
contracts_dir=""
bindings_dir=""
bind_stamp=""
bindings_filter=""
forge_path=""
declare -a bind_args=()
declare -a source_labels=()
declare -a source_paths=()

cleanup() {
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf -- "$temp_dir"
    fi
}
trap cleanup EXIT

error() {
    printf 'error: %s\n' "$1" >&2
}

usage() {
    error "usage: contract-bindings.sh digest|generate|verify prt|rollups"
    return 2
}

add_source_root() {
    source_labels+=("$1")
    source_paths+=("$2")
}

configure_module() {
    module_name="$1"
    case "$module_name" in
        prt)
            contracts_dir="${repo_dir}/prt/contracts"
            bindings_filter='^(CartesiStateTransition|MultiLevelTournamentFactory|Tournament)$'
            ;;
        rollups)
            contracts_dir="${repo_dir}/cartesi-rollups/contracts"
            bindings_filter='^(I?DaveConsensus|I?DaveAppFactory)$'
            ;;
        *)
            error "unknown bindings module: ${module_name}"
            return 2
            ;;
    esac

    bindings_dir="${contracts_dir}/bindings-rs/src/contract"
    bind_stamp="${contracts_dir}/bindings-rs/src/.bind-stamp"
    bind_args=(
        bind
        --force
        --alloy
        --alloy-version 2
        --select "$bindings_filter"
        --module
        --bindings-path "./bindings-rs/src/contract"
        --skip-extra-derives
        --root "."
    )
}

resolve_forge() {
    local candidate="" candidate_dir=""

    if ! candidate="$(type -P forge 2>/dev/null)" || [[ -z "$candidate" ]]; then
        error "required binding checker tool is missing: forge"
        return 2
    fi
    if ! candidate_dir="$(CDPATH= cd -- "$(dirname -- "$candidate")" && pwd -P)"; then
        error "cannot resolve the Forge executable"
        return 2
    fi
    forge_path="${candidate_dir}/$(basename -- "$candidate")"
    if [[ ! -x "$forge_path" ]]; then
        error "Forge is not executable: $forge_path"
        return 2
    fi
}

binding_forge() {
    FOUNDRY_TEST="$disabled_test_root" \
        FOUNDRY_SCRIPT="$disabled_script_root" \
        "$forge_path" "$@"
}

check_disabled_source_roots() {
    local root=""

    for root in "$disabled_test_root" "$disabled_script_root"; do
        if [[ -e "${contracts_dir}/${root}" || -L "${contracts_dir}/${root}" ]]; then
            error "reserved binding source path exists: ${root}"
            return 2
        fi
    done
}

append_local_source_roots() {
    local config="$1"
    local target=""

    if ! target="$(
        printf '%s\n' "$config" | jq -er '
            .src | select(type == "string" and length > 0)
        ' 2>&1
    )"; then
        error "cannot read the local source root from the effective Forge configuration"
        return 2
    fi
    target="${target%/}"
    add_source_root "local:${target}" "${contracts_dir}/${target}"
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "required binding checker tool is missing: $1"
        return 2
    fi
}

make_temp_dir() {
    if [[ -n "$temp_dir" ]]; then
        return 0
    fi
    if ! temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dave-contract-bindings.XXXXXX")"; then
        error "cannot create a temporary directory for the binding digest"
        return 2
    fi
}

append_file_digest() {
    local label="$1"
    local path="$2"
    local digest=""

    if [[ ! -f "$path" ]]; then
        error "binding input is missing: ${label}"
        return 1
    fi
    if ! digest="$(sha256sum "$path" 2>/dev/null)"; then
        error "cannot hash binding input: ${label}"
        return 2
    fi
    digest="${digest%% *}"
    printf 'file\t%s\t%s\n' "$label" "$digest" >>"${temp_dir}/manifest"
}

append_source_tree() {
    local label="$1"
    local root="$2"
    local index="$3"
    local list_file="${temp_dir}/source-list.${index}"
    local digest_file="${temp_dir}/source-digest.${index}"

    if [[ ! -d "$root" ]]; then
        error "binding source root is missing: ${label}"
        return 1
    fi
    if ! (
        CDPATH= cd -- "$root" || exit 2
        find . -type f -name '*.sol' -print0 | LC_ALL=C sort -z
    ) >"$list_file"; then
        error "cannot enumerate binding source root: ${label}"
        return 2
    fi
    if [[ ! -s "$list_file" ]]; then
        error "binding source root has no Solidity sources: ${label}"
        return 1
    fi
    if ! (
        CDPATH= cd -- "$root" || exit 2
        xargs -0 sha256sum <"$list_file"
    ) >"$digest_file"; then
        error "cannot hash binding source root: ${label}"
        return 2
    fi

    printf 'source-root\t%s\n' "$label" >>"${temp_dir}/manifest"
    cat "$digest_file" >>"${temp_dir}/manifest"
}

append_import_roots() {
    local config="$1"
    local targets=""
    local target="" resolved="" existing=""
    local covered=0
    local jq_status=0
    declare -a dependency_paths=()

    targets="$(
        printf '%s\n' "$config" | jq -r '
            [
                .libs[]?,
                (.remappings[]?
                    | select(startswith("prt-contracts-test/=") | not)
                    | sub("^[^=]+="; ""))
            ]
            | unique[]
        '
    )"
    jq_status=$?
    if ((jq_status != 0)); then
        error "cannot read dependency roots from the effective Forge configuration"
        return 2
    fi

    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        target="${target%/}"
        if ! resolved="$(CDPATH= cd -- "${contracts_dir}/${target}" 2>/dev/null && pwd -P)"; then
            error "configured binding dependency root is missing: ${target}"
            return 1
        fi

        covered=0
        if ((${#dependency_paths[@]} > 0)); then
            for existing in "${dependency_paths[@]}"; do
                case "${resolved}/" in
                    "${existing}/"*) covered=1 ;;
                esac
            done
        fi
        if ((covered)); then
            continue
        fi

        dependency_paths+=("$resolved")
        add_source_root "import:${target}" "$resolved"
    done <<<"$targets"
}

calculate_digest() {
    local forge_version="" raw_config="" effective_config=""
    local index=0 argument="" digest=""
    local rc=0

    for tool in jq sha256sum find sort xargs mktemp; do
        require_tool "$tool" || return $?
    done
    check_disabled_source_roots || return $?
    make_temp_dir || return $?
    : >"${temp_dir}/manifest" || {
        error "cannot initialize the binding digest manifest"
        return 2
    }

    if ! forge_version="$(CDPATH= cd -- "$contracts_dir" && "$forge_path" --version 2>&1)"; then
        error "cannot read the Forge version"
        return 2
    fi
    if ! raw_config="$(CDPATH= cd -- "$contracts_dir" && binding_forge config --json 2>&1)"; then
        error "cannot read the effective Forge configuration"
        return 2
    fi
    if ! effective_config="$(
        printf '%s\n' "$raw_config" | jq -cS '
            {
                additional_compiler_profiles,
                allow_paths,
                auto_detect_remappings,
                auto_detect_solc,
                bytecode_hash,
                cbor_metadata,
                compilation_restrictions,
                deny,
                dependencies,
                evm_version,
                extra_output,
                extra_output_files,
                include_paths,
                libraries,
                libs,
                optimizer,
                optimizer_details,
                optimizer_runs,
                remappings,
                revert_strings,
                solc,
                soldeer,
                sparse_mode,
                skip,
                src,
                test,
                script,
                use_literal_content,
                via_ir
            }
        ' 2>&1
    )"; then
        error "cannot canonicalize the effective Forge configuration"
        return 2
    fi

    printf 'contract-bindings-v1\n' >>"${temp_dir}/manifest"
    printf 'module\t%s\n' "$module_name" >>"${temp_dir}/manifest"
    append_file_digest "generator" "$script_path" || return $?
    append_file_digest "soldeer.lock" "${contracts_dir}/soldeer.lock" || return $?
    append_file_digest "forge-binary" "$forge_path" || return $?
    printf 'forge-version\n%s\n' "$forge_version" >>"${temp_dir}/manifest"
    printf 'forge-config\n%s\n' "$effective_config" >>"${temp_dir}/manifest"
    printf 'forge-environment\tFOUNDRY_TEST=%s\n' "$disabled_test_root" \
        >>"${temp_dir}/manifest"
    printf 'forge-environment\tFOUNDRY_SCRIPT=%s\n' "$disabled_script_root" \
        >>"${temp_dir}/manifest"
    for argument in "${bind_args[@]}"; do
        printf 'forge-argument\t%s\n' "$argument" >>"${temp_dir}/manifest"
    done

    append_local_source_roots "$raw_config"
    rc=$?
    if ((rc != 0)); then
        return "$rc"
    fi
    append_import_roots "$raw_config"
    rc=$?
    if ((rc != 0)); then
        return "$rc"
    fi

    for ((index = 0; index < ${#source_paths[@]}; index++)); do
        append_source_tree "${source_labels[$index]}" "${source_paths[$index]}" "$index" \
            || return $?
    done

    if ! digest="$(sha256sum "${temp_dir}/manifest")"; then
        error "cannot calculate the binding input digest"
        return 2
    fi
    printf '%s\n' "${digest%% *}"
}

read_stamp() {
    local stamp_line="" extra_line=""
    local first_status=0 extra_status=0

    if [[ ! -f "$bind_stamp" ]]; then
        error "binding stamp is missing"
        return 1
    fi
    if ! { exec 3<"$bind_stamp"; } 2>/dev/null; then
        error "cannot read the binding stamp"
        return 2
    fi
    IFS= read -r stamp_line <&3
    first_status=$?
    IFS= read -r extra_line <&3
    extra_status=$?
    exec 3<&-

    if { ((first_status != 0)) && [[ -z "$stamp_line" ]]; } \
        || ((extra_status == 0)) || [[ -n "$extra_line" ]] \
        || [[ ! "$stamp_line" =~ ^[0-9a-f]{64}$ ]]; then
        error "binding stamp is malformed"
        return 1
    fi
    printf '%s\n' "$stamp_line"
}

verify_bindings() {
    local expected="" actual=""
    local rc=0

    expected="$(calculate_digest)"
    rc=$?
    if ((rc != 0)); then
        return "$rc"
    fi
    if [[ ! -d "$bindings_dir" || ! -s "${bindings_dir}/mod.rs" ]]; then
        error "generated Rust bindings are missing or incomplete"
        return 1
    fi
    actual="$(read_stamp)"
    rc=$?
    if ((rc != 0)); then
        return "$rc"
    fi
    if [[ "$actual" != "$expected" ]]; then
        error "generated Rust bindings are stale"
        return 1
    fi
}

generate_bindings() {
    local expected="" actual="" stamp_temp=""
    local rc=0

    expected="$(calculate_digest)"
    rc=$?
    if ((rc != 0)); then
        return "$rc"
    fi
    if [[ -d "$bindings_dir" && -s "${bindings_dir}/mod.rs" ]]; then
        actual="$(read_stamp 2>/dev/null)"
        rc=$?
        if ((rc == 0)) && [[ "$actual" == "$expected" ]]; then
            return 0
        fi
        if ((rc == 2)); then
            read_stamp >/dev/null
            return 2
        fi
    fi

    rm -f -- "$bind_stamp"
    rm -rf -- "$bindings_dir"
    if ! (CDPATH= cd -- "$contracts_dir" && binding_forge "${bind_args[@]}"); then
        error "Forge failed to generate ${module_name} Rust bindings"
        return 1
    fi
    if [[ ! -s "${bindings_dir}/mod.rs" ]]; then
        error "Forge did not produce a nonempty Rust binding module"
        return 2
    fi
    if ! stamp_temp="$(mktemp "${bind_stamp}.tmp.XXXXXX")"; then
        error "cannot create the binding stamp"
        return 2
    fi
    if ! printf '%s\n' "$expected" >"$stamp_temp"; then
        error "cannot write the binding stamp"
        rm -f -- "$stamp_temp"
        return 2
    fi
    if ! mv -f -- "$stamp_temp" "$bind_stamp"; then
        error "cannot publish the binding stamp"
        rm -f -- "$stamp_temp"
        return 2
    fi
}

if (($# != 2)); then
    usage
    exit $?
fi

readonly action="$1"
configure_module "$2" || exit $?
resolve_forge || exit $?

case "$action" in
    digest) calculate_digest ;;
    generate) generate_bindings ;;
    verify) verify_bindings ;;
    *) usage ;;
esac
