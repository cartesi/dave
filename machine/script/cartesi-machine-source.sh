#!/usr/bin/env bash
# Prepares machine/emulator as Cargo's source provider or validates an
# external one; machine/README.md documents the provider contract.
#
# Nothing here takes a lock. The state file and the Boost stamp land only
# with or after the content they vouch for, so an interrupted or concurrent
# run fails a later check instead of passing it, and rerunning repairs it.
set -euo pipefail

readonly release_tag="v0.21.0"
readonly release_commit="bd09538131e589319e371d7d65e81c2c82dd3411"
readonly release_patch_sha256="596c5e171cac2e784aef01a26d47d19964b8593f74e37e863e0fcc1c9446be23"
readonly release_patch_url="https://github.com/cartesi/machine-emulator/releases/download/${release_tag}/add-generated-files.diff"

readonly boost_version="1.83.0"
readonly boost_archive_name="boost_1_83_0.tar.gz"
readonly boost_archive_sha256="c0685b68dd44cc46574cce86c4e17c0f611b15e195be9848dfd0769a0a207628"
readonly boost_archive_url="https://archives.boost.io/release/${boost_version}/source/${boost_archive_name}"

readonly script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly machine_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd -P)"
readonly repo_root="$(CDPATH= cd -- "${machine_dir}/.." && pwd -P)"
readonly emulator_dir="${machine_dir}/emulator"
readonly cache_root="${repo_root}/target/machine-source"
readonly source_state="${cache_root}/prepared-generated-sources"
readonly boost_dir="${emulator_dir}/third-party/downloads/boost"
readonly boost_stamp="${boost_dir}/.dave-archive-sha256"

readonly generated_files=(
    "src/cm-version.h"
    "src/interpret-jump-table.hpp"
    "uarch/uarch-pristine-hash.c"
    "uarch/uarch-pristine-ram.c"
)

temporary_paths=()

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "required tool '$1' is not on PATH"
}

remember_temporary_path() {
    temporary_paths+=("$1")
}

cleanup_temporary_paths() {
    local path
    if (( ${#temporary_paths[@]} == 0 )); then
        return
    fi
    for path in "${temporary_paths[@]}"; do
        case "$path" in
            "${cache_root}"/*)
                if [[ -e "$path" || -L "$path" ]]; then
                    rm -rf -- "$path"
                fi
                ;;
        esac
    done
}

trap cleanup_temporary_paths EXIT

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
    [[ -f "$1" ]] && [[ "$(sha256_of "$1")" == "$2" ]]
}

require_emulator() {
    require_emulator_sources
    [[ -e "${emulator_dir}/.git" ]] ||
        die "machine/emulator is not initialized; run 'just machine::setup'"
}

require_emulator_sources() {
    [[ -f "${emulator_dir}/Makefile" ]] ||
        die "machine/emulator source tree is unavailable"
}

require_clean_emulator() {
    git -C "$emulator_dir" diff --quiet -- ||
        die "machine/emulator has tracked worktree changes"
    git -C "$emulator_dir" diff --cached --quiet -- ||
        die "machine/emulator has staged changes"
}

emulator_head() {
    git -C "$emulator_dir" rev-parse --verify 'HEAD^{commit}'
}

lua54_command() {
    local candidate version

    for candidate in lua5.4 lua; do
        if command -v "$candidate" >/dev/null 2>&1; then
            version="$("$candidate" -v 2>&1)"
            case "$version" in
                "Lua 5.4"*)
                    command -v "$candidate"
                    return
                    ;;
            esac
        fi
    done
    die "Lua 5.4 is required to generate Cartesi Machine sources"
}

extract_generated_patch() {
    local patch="$1"
    local destination="$2"
    local actual_status
    local expected_status
    local count=0
    local mode object stage path

    mkdir -p -- "$destination"
    git -C "$destination" init -q
    git -C "$destination" apply --index "$patch"

    expected_status=$'A\tsrc/cm-version.h\nA\tsrc/interpret-jump-table.hpp\nA\tuarch/uarch-pristine-hash.c\nA\tuarch/uarch-pristine-ram.c'
    actual_status="$(git -C "$destination" diff --cached --name-status)"
    [[ "$actual_status" == "$expected_status" ]] || {
        printf 'unexpected generated-files patch contents:\n%s\n' "$actual_status" >&2
        die "generated-files patch must add exactly the four expected files"
    }

    while read -r mode object stage path; do
        [[ "$mode" == "100644" && "$stage" == "0" ]] ||
            die "generated-files patch has an unexpected mode for $path"
        [[ -s "${destination}/${path}" && ! -L "${destination}/${path}" ]] ||
            die "generated-files patch did not produce a regular nonempty file: $path"
        count=$((count + 1))
    done < <(git -C "$destination" ls-files --stage)
    [[ "$count" -eq 4 ]] || die "generated-files patch produced $count files, expected 4"
}

publish_generated_sources() {
    local extracted="$1"
    local provider="$2"
    local head="$3"
    local path target temporary_state

    for path in "${generated_files[@]}"; do
        git -C "$emulator_dir" check-ignore -q -- "$path" ||
            die "refusing to replace a generated path that is not ignored: $path"
        if git -C "$emulator_dir" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            die "refusing to replace a tracked generated path: $path"
        fi
        target="${emulator_dir}/${path}"
        if [[ -e "$target" && ! -f "$target" ]] || [[ -L "$target" ]]; then
            die "refusing to replace a non-regular generated path: $path"
        fi
    done

    # Every source is extracted and validated before the checkout is mutated.
    # The staging tree and checkout share a filesystem, so each rename is atomic.
    for path in "${generated_files[@]}"; do
        chmod 0644 "${extracted}/${path}"
        mv -f -- "${extracted}/${path}" "${emulator_dir}/${path}"
    done

    temporary_state="$(mktemp "${cache_root}/.prepared-generated-sources.XXXXXX")"
    remember_temporary_path "$temporary_state"
    {
        printf 'format 1\n'
        printf 'provider %s\n' "$provider"
        printf 'emulator-head %s\n' "$head"
        for path in "${generated_files[@]}"; do
            printf 'generated %s %s\n' "$(sha256_of "${emulator_dir}/${path}")" "$path"
        done
    } >"$temporary_state"
    chmod 0644 "$temporary_state"
    mv -f -- "$temporary_state" "$source_state"
}

generated_sources_match() {
    local expected_provider="$1"
    local expected_head="$2"
    local path expected_sha256 matches

    [[ -f "$source_state" ]] || return 1
    [[ "$(wc -l <"$source_state" | tr -d ' ')" == "7" ]] || return 1
    [[ "$(sed -n '1p' "$source_state")" == "format 1" ]] || return 1
    [[ "$(sed -n 's/^provider //p' "$source_state")" == "$expected_provider" ]] || return 1
    [[ "$(sed -n 's/^emulator-head //p' "$source_state")" == "$expected_head" ]] || return 1
    for path in "${generated_files[@]}"; do
        matches="$(awk -v path="$path" '$1 == "generated" && $3 == path { count += 1 } END { print count + 0 }' "$source_state")"
        [[ "$matches" == "1" ]] || return 1
        expected_sha256="$(awk -v path="$path" '$1 == "generated" && $3 == path { print $2 }' "$source_state")"
        verify_sha256 "${emulator_dir}/${path}" "$expected_sha256" || return 1
    done
}

prepare_release() {
    local head patch extraction

    need git
    need sha256sum
    require_emulator
    require_clean_emulator

    head="$(emulator_head)"
    [[ "$head" == "$release_commit" ]] ||
        die "${release_tag} generated sources require emulator HEAD ${release_commit}, found ${head}"

    if generated_sources_match "release:${release_tag}" "$head"; then
        printf 'Cartesi Machine %s generated sources already prepared\n' "$release_tag"
        return
    fi

    patch="${cache_root}/release/${release_tag}-${release_patch_sha256}/add-generated-files.diff"
    "${repo_root}/script/fetch.sh" "$release_patch_url" "$release_patch_sha256" "$patch"

    extraction="$(mktemp -d "${cache_root}/.release-generated.XXXXXX")"
    remember_temporary_path "$extraction"
    extract_generated_patch "$patch" "$extraction"
    publish_generated_sources "$extraction" "release:${release_tag}" "$head"
    printf 'prepared Cartesi Machine %s generated sources\n' "$release_tag"
}

boost_is_prepared() {
    [[ -f "$boost_stamp" && "$(cat "$boost_stamp")" == "$boost_archive_sha256" ]] &&
        [[ -f "${boost_dir}/version.hpp" ]] &&
        grep -Eq '^#define BOOST_VERSION +108300$' "${boost_dir}/version.hpp"
}

# The archive is pinned by SHA-256, so its contents are trusted as published
# and tar's own member-name rules suffice.
prepare_boost() {
    local archive extraction extracted_boost

    require_emulator_sources

    if boost_is_prepared; then
        printf 'Boost %s headers already prepared\n' "$boost_version"
        return
    fi

    need sha256sum
    need tar

    archive="${cache_root}/dependency/boost-${boost_version}-${boost_archive_sha256}/${boost_archive_name}"
    "${repo_root}/script/fetch.sh" "$boost_archive_url" "$boost_archive_sha256" "$archive"

    extraction="$(mktemp -d "${cache_root}/.boost-extract.XXXXXX")"
    remember_temporary_path "$extraction"
    tar -xzf "$archive" -C "$extraction" boost_1_83_0/boost
    extracted_boost="${extraction}/boost_1_83_0/boost"
    grep -Eq '^#define BOOST_VERSION +108300$' "${extracted_boost}/version.hpp" ||
        die "Boost extraction has an unexpected version"
    printf '%s\n' "$boost_archive_sha256" >"${extracted_boost}/.dave-archive-sha256"

    # Unstamp first: a replacement cut short leaves no stamp, so the next run
    # starts over instead of trusting a partial tree.
    rm -f -- "$boost_stamp"
    rm -rf -- "$boost_dir"
    mkdir -p -- "$(dirname "$boost_dir")"
    mv -- "$extracted_boost" "$boost_dir"
    printf 'prepared Boost %s headers\n' "$boost_version"
}

generate_sources() {
    local head generation clone patch extraction path lua_bin

    need git
    need make
    require_emulator
    require_clean_emulator
    head="$(emulator_head)"

    if generated_sources_match "generated" "$head"; then
        printf 'Cartesi Machine sources already generated for %s\n' "$head"
        return
    fi

    generation="$(mktemp -d "${cache_root}/.source-generation.XXXXXX")"
    remember_temporary_path "$generation"
    clone="${generation}/emulator"
    git clone --quiet --no-hardlinks --no-checkout "$emulator_dir" "$clone"
    git -C "$clone" checkout --quiet --detach "$head"

    if [[ "${DEV_ENV_HAS_TOOLCHAIN:-}" != "yes" ]]; then
        need docker
        # Upstream otherwise reuses any image carrying this global tag. Rebuild
        # it from the selected checkout; Docker still reuses matching layers.
        make -C "$clone" build-toolchain
        make -C "$clone" uarch-with-toolchain
    else
        lua_bin="$(lua54_command)"
        make -C "$clone" LUA_BIN="$lua_bin" uarch
    fi
    make -C "$clone" create-generated-files-patch
    patch="${clone}/add-generated-files.diff"
    [[ -f "$patch" ]] || die "upstream generator did not produce add-generated-files.diff"

    extraction="${generation}/validated"
    extract_generated_patch "$patch" "$extraction"
    for path in "${generated_files[@]}"; do
        cmp -s "${clone}/${path}" "${extraction}/${path}" ||
            die "generated source does not match its patch: $path"
    done
    publish_generated_sources "$extraction" "generated" "$head"
    printf 'generated Cartesi Machine sources for %s\n' "$head"
}

validate_generated_sources() {
    local head recorded_head recorded_provider

    [[ -f "$source_state" ]] ||
        die "generated sources are not prepared; run 'just machine::prepare-release' or 'just machine::generate-sources'"
    [[ "$(sed -n '1p' "$source_state")" == "format 1" ]] ||
        die "generated-source preparation state has an unsupported format"
    recorded_provider="$(sed -n 's/^provider //p' "$source_state")"
    recorded_head="$(sed -n 's/^emulator-head //p' "$source_state")"
    case "$recorded_provider" in
        "release:${release_tag}")
            [[ "$recorded_head" == "$release_commit" ]] ||
                die "release preparation state names the wrong emulator commit"
            ;;
        generated) ;;
        *) die "generated-source preparation state has an invalid provider" ;;
    esac
    head="$(emulator_head)"
    [[ "$recorded_head" == "$head" ]] ||
        die "prepared sources belong to emulator ${recorded_head}, but HEAD is ${head}"
    generated_sources_match "$recorded_provider" "$head" ||
        die "generated-source preparation state or published sources do not match exactly"
}

external_provider_selected() {
    [[ "${LIBCARTESI_PATH+x}" == "x" ]]
}

validate_external_provider() {
    local lib_dir include_dir

    [[ -n "${LIBCARTESI_PATH}" ]] || die "LIBCARTESI_PATH is set but empty"
    [[ "${LIBCARTESI_PATH}" == /* ]] ||
        die "LIBCARTESI_PATH must be absolute: ${LIBCARTESI_PATH}"
    [[ -d "${LIBCARTESI_PATH}" ]] ||
        die "LIBCARTESI_PATH is not a directory: ${LIBCARTESI_PATH}"
    lib_dir="${LIBCARTESI_PATH}"
    [[ -f "${lib_dir}/libcartesi.a" ]] ||
        die "external provider lacks ${lib_dir}/libcartesi.a"

    if [[ "${INCLUDECARTESI_PATH+x}" == "x" ]]; then
        [[ -n "${INCLUDECARTESI_PATH}" ]] || die "INCLUDECARTESI_PATH is set but empty"
        [[ "${INCLUDECARTESI_PATH}" == /* ]] ||
            die "INCLUDECARTESI_PATH must be absolute: ${INCLUDECARTESI_PATH}"
        include_dir="${INCLUDECARTESI_PATH}"
    else
        include_dir="$(dirname "$lib_dir")/include/cartesi-machine"
    fi
    [[ -f "${include_dir}/cm.h" ]] ||
        die "external provider lacks ${include_dir}/cm.h"
    [[ -f "${include_dir}/cm-version.h" ]] ||
        die "external provider lacks ${include_dir}/cm-version.h"
    printf 'using external Cartesi Machine provider:\n  library: %s\n  headers: %s\n' \
        "$lib_dir" "$include_dir"
}

build_source() {
    local jobs

    if external_provider_selected; then
        validate_external_provider
        return
    fi

    need make
    require_emulator
    require_clean_emulator
    validate_generated_sources
    boost_is_prepared ||
        die "Boost headers are not prepared; run 'just machine::prepare-boost'"

    jobs="${DAVE_MACHINE_BUILD_JOBS:-}"
    if [[ -z "$jobs" ]] && command -v getconf >/dev/null 2>&1; then
        jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    fi
    if [[ -z "$jobs" ]] && command -v sysctl >/dev/null 2>&1; then
        jobs="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || jobs=1

    make -C "${emulator_dir}/src" -j"$jobs" \
        release=yes slirp=no libcartesi.a libcartesi_jsonrpc.a
}

setup_provider() {
    if external_provider_selected; then
        validate_external_provider
        printf 'external provider selected; skipping emulator source setup\n'
        return
    fi

    need git
    git -C "$repo_root" submodule update --init -- machine/emulator
    prepare_release
    prepare_boost
    build_source
}

check_provider() {
    if external_provider_selected; then
        validate_external_provider
        printf 'external Cartesi Machine provider is ready\n'
        return
    fi

    require_emulator
    require_clean_emulator
    validate_generated_sources
    boost_is_prepared || die "prepared Boost headers are missing or invalid"
    [[ -f "${emulator_dir}/src/libcartesi.a" ]] ||
        die "source provider has not built libcartesi.a"
    [[ -f "${emulator_dir}/src/libcartesi_jsonrpc.a" ]] ||
        die "source provider has not built libcartesi_jsonrpc.a"
    printf 'Cartesi Machine source provider is ready\n'
}

clean_source() {
    local path target git_checkout=0

    if git -C "$emulator_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_checkout=1
    fi
    for path in "${generated_files[@]}"; do
        target="${emulator_dir}/${path}"
        if [[ "$git_checkout" == "1" ]] &&
            git -C "$emulator_dir" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            die "refusing to clean a tracked generated path: $path"
        fi
        if [[ "$git_checkout" == "1" ]] &&
            ! git -C "$emulator_dir" check-ignore -q -- "$path"; then
            die "refusing to clean a generated path that is not ignored: $path"
        fi
        if [[ -L "$target" ]] || [[ -e "$target" && ! -f "$target" ]]; then
            die "refusing to clean a non-regular generated path: $path"
        fi
    done

    if [[ -f "${emulator_dir}/src/Makefile" ]]; then
        make -C "${emulator_dir}/src" clean
    fi
    if [[ -f "${emulator_dir}/uarch/Makefile" ]]; then
        make -C "${emulator_dir}/uarch" clean
    fi
    for path in "${generated_files[@]}"; do
        target="${emulator_dir}/${path}"
        if [[ -e "$target" ]]; then
            rm -f -- "$target"
        fi
    done
    case "$boost_dir" in
        "${emulator_dir}/third-party/downloads/boost")
            if [[ -e "$boost_dir" || -L "$boost_dir" ]]; then
                rm -rf -- "$boost_dir"
            fi
            ;;
        *) die "internal error: unsafe Boost clean target" ;;
    esac
    if [[ -f "$source_state" ]]; then
        rm -f -- "$source_state"
    fi
    printf 'removed Cartesi Machine source-provider outputs; download caches retained\n'
}

case "${1:-}" in
    prepare-release) prepare_release ;;
    prepare-boost) prepare_boost ;;
    generate-sources) generate_sources ;;
    build) build_source ;;
    setup) setup_provider ;;
    check) check_provider ;;
    clean) clean_source ;;
    *)
        printf 'usage: %s {prepare-release|prepare-boost|generate-sources|build|setup|check|clean}\n' "$0" >&2
        exit 2
        ;;
esac
