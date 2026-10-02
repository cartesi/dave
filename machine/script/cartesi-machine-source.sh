#!/usr/bin/env bash
# Prepares machine/emulator as Cargo's source provider or validates an
# external one; machine/README.md documents the provider contract.
#
# Nothing here takes a lock, so run one preparation per checkout at a time;
# two concurrent prepare-boost runs can nest one tree inside the other. The
# state file and the Boost stamp land only with or after the content they
# vouch for, so an interrupted run fails a later check instead of passing it,
# and rerunning repairs it.
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

work_dir=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "required tool '$1' is not on PATH"
}

cleanup() {
    if [[ -n "$work_dir" ]]; then
        rm -rf -- "$work_dir"
    fi
}

trap cleanup EXIT

# Scratch space sits under the cache, on the checkout's filesystem, so moving
# prepared files into the checkout is a rename.
make_work_dir() {
    if [[ -z "$work_dir" ]]; then
        mkdir -p -- "$cache_root"
        work_dir="$(mktemp -d "${cache_root}/.work.XXXXXX")"
    fi
}

sha256_of() {
    [[ -f "$1" ]] || return 1
    sha256sum "$1" | awk '{print $1}'
}

require_emulator_sources() {
    [[ -f "${emulator_dir}/Makefile" ]] ||
        die "machine/emulator source tree is unavailable"
}

# Generated files are keyed to the checkout's HEAD, so it must be an
# initialized submodule without tracked changes.
require_clean_emulator() {
    require_emulator_sources
    [[ -e "${emulator_dir}/.git" ]] ||
        die "machine/emulator is not initialized; run 'just machine::setup'"
    git -C "$emulator_dir" diff --quiet -- ||
        die "machine/emulator has tracked worktree changes"
    git -C "$emulator_dir" diff --cached --quiet -- ||
        die "machine/emulator has staged changes"
}

emulator_head() {
    git -C "$emulator_dir" rev-parse --verify 'HEAD^{commit}'
}

lua54_command() {
    local candidate

    for candidate in lua5.4 lua; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            [[ "$("$candidate" -v 2>&1)" == "Lua 5.4"* ]]; then
            command -v "$candidate"
            return
        fi
    done
    die "Lua 5.4 is required to generate Cartesi Machine sources"
}

# Applied to an empty index, a generated-files patch must add exactly the four
# generated files, as regular nonempty files.
extract_generated_patch() {
    local patch="$1" destination="$2" expected actual path

    mkdir -p -- "$destination"
    git -C "$destination" init -q
    git -C "$destination" apply --index "$patch"
    expected="$(printf '100644 0 %s\n' "${generated_files[@]}")"
    actual="$(git -C "$destination" ls-files --stage | awk '{print $1, $3, $4}')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'unexpected generated-files patch contents:\n%s\n' "$actual" >&2
        die "generated-files patch must add exactly the four expected regular files"
    fi
    for path in "${generated_files[@]}"; do
        [[ -s "${destination}/${path}" ]] ||
            die "generated-files patch produced an empty file: $path"
    done
}

# check-ignore also fails for tracked paths, so publishing or cleaning the
# generated paths never touches an upstream source.
require_generated_paths_ignored() {
    local path

    for path in "${generated_files[@]}"; do
        git -C "$emulator_dir" check-ignore -q -- "$path" ||
            die "refusing to touch a generated path that is tracked or not ignored: $path"
    done
}

# The files are validated before the checkout changes, and the state that
# vouches for them is renamed in last.
publish_generated_sources() {
    local extracted="$1" provider="$2" head="$3" path

    require_generated_paths_ignored
    for path in "${generated_files[@]}"; do
        chmod 0644 "${extracted}/${path}"
        mv -f -- "${extracted}/${path}" "${emulator_dir}/${path}"
    done
    render_state "$provider" "$head" >"${work_dir}/state"
    mv -f -- "${work_dir}/state" "$source_state"
}

# build.rs parses this exact seven-line format: the provider, the emulator
# commit, and the digest of each published file in generated_files order.
render_state() {
    local path

    printf 'format 1\nprovider %s\nemulator-head %s\n' "$1" "$2"
    for path in "${generated_files[@]}"; do
        printf 'generated %s %s\n' "$(sha256_of "${emulator_dir}/${path}")" "$path"
    done
}

# Comparing the recorded state with one rendered from the checkout checks the
# format, provider, commit, and every digest at once. It uses cmp because
# command substitution drops trailing blank lines, which build.rs rejects.
generated_sources_match() {
    [[ -f "$source_state" ]] && render_state "$1" "$2" | cmp -s - "$source_state"
}

prepare_release() {
    local head patch

    need git
    need sha256sum
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

    make_work_dir
    extract_generated_patch "$patch" "${work_dir}/release"
    publish_generated_sources "${work_dir}/release" "release:${release_tag}" "$head"
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
    local archive extracted

    require_emulator_sources

    if boost_is_prepared; then
        printf 'Boost %s headers already prepared\n' "$boost_version"
        return
    fi

    need sha256sum
    need tar

    archive="${cache_root}/dependency/boost-${boost_version}-${boost_archive_sha256}/${boost_archive_name}"
    "${repo_root}/script/fetch.sh" "$boost_archive_url" "$boost_archive_sha256" "$archive"

    make_work_dir
    tar -xzf "$archive" -C "$work_dir" boost_1_83_0/boost
    extracted="${work_dir}/boost_1_83_0/boost"
    grep -Eq '^#define BOOST_VERSION +108300$' "${extracted}/version.hpp" ||
        die "Boost extraction has an unexpected version"
    printf '%s\n' "$boost_archive_sha256" >"${extracted}/.dave-archive-sha256"

    # Unstamp first: a replacement cut short leaves no stamp, so the next run
    # starts over instead of trusting a partial tree.
    rm -f -- "$boost_stamp"
    rm -rf -- "$boost_dir"
    mkdir -p -- "$(dirname "$boost_dir")"
    mv -- "$extracted" "$boost_dir"
    printf 'prepared Boost %s headers\n' "$boost_version"
}

generate_sources() {
    local head clone patch path lua_bin

    need git
    need make
    require_clean_emulator
    head="$(emulator_head)"

    if generated_sources_match "generated" "$head"; then
        printf 'Cartesi Machine sources already generated for %s\n' "$head"
        return
    fi

    make_work_dir
    clone="${work_dir}/emulator"
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

    extract_generated_patch "$patch" "${work_dir}/validated"
    for path in "${generated_files[@]}"; do
        cmp -s "${clone}/${path}" "${work_dir}/validated/${path}" ||
            die "generated source does not match its patch: $path"
    done
    publish_generated_sources "${work_dir}/validated" "generated" "$head"
    printf 'generated Cartesi Machine sources for %s\n' "$head"
}

validate_generated_sources() {
    local provider head

    [[ -f "$source_state" ]] ||
        die "generated sources are not prepared; run 'just machine::prepare-release' or 'just machine::generate-sources'"
    provider="$(sed -n 's/^provider //p' "$source_state")"
    head="$(emulator_head)"
    case "$provider" in
        "release:${release_tag}")
            [[ "$head" == "$release_commit" ]] ||
                die "${release_tag} sources are prepared, but emulator HEAD is ${head}"
            ;;
        generated) ;;
        *) die "generated-source preparation state names an unknown provider: ${provider}" ;;
    esac
    generated_sources_match "$provider" "$head" ||
        die "prepared sources or their recorded state do not match emulator HEAD ${head}; rerun 'just machine::prepare-release' or 'just machine::generate-sources'"
}

external_provider_selected() {
    [[ "${LIBCARTESI_PATH+x}" == "x" ]]
}

validate_external_provider() {
    local include_dir

    [[ -n "${LIBCARTESI_PATH}" ]] || die "LIBCARTESI_PATH is set but empty"
    [[ "${LIBCARTESI_PATH}" == /* ]] ||
        die "LIBCARTESI_PATH must be absolute: ${LIBCARTESI_PATH}"
    [[ -d "${LIBCARTESI_PATH}" ]] ||
        die "LIBCARTESI_PATH is not a directory: ${LIBCARTESI_PATH}"
    [[ -f "${LIBCARTESI_PATH}/libcartesi.a" ]] ||
        die "external provider lacks ${LIBCARTESI_PATH}/libcartesi.a"

    if [[ "${INCLUDECARTESI_PATH+x}" == "x" ]]; then
        [[ -n "${INCLUDECARTESI_PATH}" ]] || die "INCLUDECARTESI_PATH is set but empty"
        [[ "${INCLUDECARTESI_PATH}" == /* ]] ||
            die "INCLUDECARTESI_PATH must be absolute: ${INCLUDECARTESI_PATH}"
        include_dir="${INCLUDECARTESI_PATH}"
    else
        include_dir="$(dirname "$LIBCARTESI_PATH")/include/cartesi-machine"
    fi
    [[ -f "${include_dir}/cm.h" ]] ||
        die "external provider lacks ${include_dir}/cm.h"
    [[ -f "${include_dir}/cm-version.h" ]] ||
        die "external provider lacks ${include_dir}/cm-version.h"
    printf 'using external Cartesi Machine provider:\n  library: %s\n  headers: %s\n' \
        "$LIBCARTESI_PATH" "$include_dir"
}

require_prepared_source() {
    require_clean_emulator
    validate_generated_sources
    boost_is_prepared ||
        die "Boost headers are not prepared; run 'just machine::prepare-boost'"
}

build_source() {
    local jobs

    if external_provider_selected; then
        validate_external_provider
        return
    fi

    need make
    require_prepared_source
    jobs="${DAVE_MACHINE_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
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
    local lib

    if external_provider_selected; then
        validate_external_provider
        printf 'external Cartesi Machine provider is ready\n'
        return
    fi

    require_prepared_source
    for lib in libcartesi.a libcartesi_jsonrpc.a; do
        [[ -f "${emulator_dir}/src/${lib}" ]] || die "source provider has not built ${lib}"
    done
    printf 'Cartesi Machine source provider is ready\n'
}

clean_source() {
    local dir path

    # Without its own .git the tree cannot say which paths it ignores.
    if [[ -e "${emulator_dir}/.git" ]]; then
        require_generated_paths_ignored
    fi
    for dir in src uarch; do
        if [[ -f "${emulator_dir}/${dir}/Makefile" ]]; then
            make -C "${emulator_dir}/${dir}" clean
        fi
    done
    for path in "${generated_files[@]}"; do
        rm -f -- "${emulator_dir}/${path}"
    done
    rm -rf -- "$boost_dir"
    rm -f -- "$source_state"
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
