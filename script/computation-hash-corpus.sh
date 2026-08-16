#!/usr/bin/env bash
#
# Download and test the computation-hash corpus published with emulator v0.21.0.
set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

readonly release_version="v0.21.0"
readonly archive_sha256="2a452f69398f6b19132ca6b5f3862fbb809b18736ffbf891bc79ba7e89b8f7bc"
readonly release_url="https://github.com/cartesi/machine-emulator/releases/download/${release_version}/computation-hash-corpus.tar.gz"
readonly cache_root="$(pwd -P)/target/computation-hash-corpus"
readonly release_cache="${cache_root}/${release_version}-${archive_sha256}"
readonly archive="${release_cache}/computation-hash-corpus.tar.gz"
readonly corpus="${release_cache}/corpus"
readonly release_marker="${corpus}/.release"
readonly prepare_lock="${release_cache}/.prepare.lock"

temporary_archive=
staging=
lock_held=0

usage() {
    cat >&2 <<'EOF'
usage:
  script/computation-hash-corpus.sh download
  script/computation-hash-corpus.sh test
EOF
    exit 2
}

cleanup() {
    [ -z "$temporary_archive" ] || rm -f -- "$temporary_archive"
    [ -z "$staging" ] || rm -rf -- "$staging"
    if [ "$lock_held" -eq 1 ]; then
        rm -f -- "$prepare_lock/pid"
        rmdir -- "$prepare_lock" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

require_tool() {
    if ! command -v "$1" >/dev/null; then
        echo "error: $1 is required for the computation-hash corpus" >&2
        exit 1
    fi
}

verify_archive() {
    [ -f "$archive" ] &&
        printf '%s  %s\n' "$archive_sha256" "$archive" |
            sha256sum -c - >/dev/null 2>&1
}

verify_corpus() {
    local recorded_release

    verify_archive || return 1
    [ -d "$corpus" ] || return 1
    [ -s "$corpus/manifest.json" ] || return 1
    [ -f "$release_marker" ] || return 1
    recorded_release=$(cat -- "$release_marker")
    [ "$recorded_release" = "$release_version $archive_sha256" ]
}

acquire_prepare_lock() {
    local attempts=0
    local holder

    while ! mkdir -- "$prepare_lock" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            holder=$(cat -- "$prepare_lock/pid" 2>/dev/null || true)
            echo "error: timed out waiting for corpus preparation${holder:+ by pid $holder}" >&2
            echo "fix: remove $prepare_lock only if no download is running" >&2
            exit 1
        fi
        sleep 1
    done
    lock_held=1
    printf '%s\n' "$$" > "$prepare_lock/pid"
}

release_prepare_lock() {
    rm -f -- "$prepare_lock/pid"
    rmdir -- "$prepare_lock"
    lock_held=0
}

validate_archive_layout() {
    local entries
    local entry
    local root_entries=0
    local listings
    local listing

    entries=$(tar -tzf "$archive")
    while IFS= read -r entry; do
        case "$entry" in
            computation-hash-corpus/)
                root_entries=$((root_entries + 1))
                ;;
            computation-hash-corpus/*)
                entry=${entry#computation-hash-corpus/}
                case "/$entry/" in
                    */../*|*/./*)
                        echo "error: unsafe path in corpus archive: $entry" >&2
                        return 1
                        ;;
                esac
                ;;
            *)
                echo "error: unexpected corpus archive root: $entry" >&2
                return 1
                ;;
        esac
    done <<< "$entries"
    if [ "$root_entries" -ne 1 ]; then
        echo "error: corpus archive must contain one computation-hash-corpus root" >&2
        return 1
    fi

    listings=$(tar -tvzf "$archive")
    while IFS= read -r listing; do
        case "${listing:0:1}" in
            -|d) ;;
            *)
                echo "error: corpus archive contains a non-file entry: $listing" >&2
                return 1
                ;;
        esac
    done <<< "$listings"
}

download_corpus() {
    require_tool sha256sum

    mkdir -p -- "$release_cache"
    if verify_corpus; then
        echo "computation-hash corpus is ready: $corpus"
        return
    fi

    require_tool curl
    require_tool mktemp
    require_tool tar
    acquire_prepare_lock
    if verify_corpus; then
        release_prepare_lock
        echo "computation-hash corpus is ready: $corpus"
        return
    fi

    if ! verify_archive; then
        temporary_archive=$(mktemp "${release_cache}/.archive.XXXXXX")
        curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
            -o "$temporary_archive" "$release_url"
        printf '%s  %s\n' "$archive_sha256" "$temporary_archive" |
            sha256sum -c -
        mv -- "$temporary_archive" "$archive"
        temporary_archive=
    fi
    validate_archive_layout

    staging=$(mktemp -d "${release_cache}/.corpus.XXXXXX")
    tar --no-same-owner --no-same-permissions \
        -xzf "$archive" -C "$staging" --strip-components=1
    if [ ! -s "$staging/manifest.json" ]; then
        echo "error: release archive does not contain a corpus manifest" >&2
        exit 1
    fi
    printf '%s %s\n' "$release_version" "$archive_sha256" > "$staging/.release"

    [ ! -e "$corpus" ] && [ ! -L "$corpus" ] || rm -rf -- "$corpus"
    mv -- "$staging" "$corpus"
    staging=

    if ! verify_corpus; then
        echo "error: failed to publish a verified computation-hash corpus" >&2
        exit 1
    fi
    release_prepare_lock
    echo "computation-hash corpus is ready: $corpus"
}

test_corpus() {
    require_tool cargo
    require_tool cartesi-machine
    require_tool sha256sum

    if ! verify_corpus; then
        echo "error: the verified computation-hash corpus is not available" >&2
        echo "fix: script/computation-hash-corpus.sh download" >&2
        exit 1
    fi

    CARTESI_COMPUTATION_HASH_CORPUS_PATH="$corpus" \
        CARTESI_MACHINE_CLI=cartesi-machine \
        cargo test --offline -p cartesi-rollups-prt-node \
            --test engine_machine \
            computation_hash_corpus_matches_cli_and_engine \
            -- --ignored --exact --nocapture
}

[ "$#" -eq 1 ] || usage

case "$1" in
    download)
        download_corpus
        ;;
    test)
        test_corpus
        ;;
    *)
        usage
        ;;
esac
