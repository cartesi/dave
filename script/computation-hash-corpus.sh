#!/usr/bin/env bash
#
# Download and test the computation-hash corpus published with emulator v0.21.0.
set -euo pipefail

cd "${BASH_SOURCE%/*}/.."

readonly release_version="v0.21.0"
readonly archive_sha256="2a452f69398f6b19132ca6b5f3862fbb809b18736ffbf891bc79ba7e89b8f7bc"
readonly manifest_sha256="d859625242f6b4947c05c152352acb259bc81c84444573f204904bf3f93612e9"
readonly release_url="https://github.com/cartesi/machine-emulator/releases/download/${release_version}/computation-hash-corpus.tar.gz"
readonly cache_root="$(pwd -P)/target/computation-hash-corpus"
readonly release_cache="${cache_root}/${release_version}-${archive_sha256}"
readonly archive="${release_cache}/computation-hash-corpus.tar.gz"
readonly corpus="${release_cache}/corpus"
readonly release_marker="${corpus}/.release"

staging=

usage() {
    cat >&2 <<'EOF'
usage:
  script/computation-hash-corpus.sh download
  script/computation-hash-corpus.sh test-cli
  script/computation-hash-corpus.sh test-dave
  script/computation-hash-corpus.sh test
EOF
    exit 2
}

trap '[ -z "$staging" ] || rm -rf -- "$staging"' EXIT
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
    local recorded_release actual_manifest

    verify_archive || return 1
    [ -d "$corpus" ] || return 1
    [ -s "$corpus/manifest.json" ] || return 1
    actual_manifest=$(sha256sum -- "$corpus/manifest.json" 2>/dev/null) || return 1
    [ "${actual_manifest%% *}" = "$manifest_sha256" ] || return 1
    [ -f "$release_marker" ] || return 1
    recorded_release=$(cat -- "$release_marker")
    [ "$recorded_release" = "$release_version $archive_sha256" ]
}

# The pinned archive needs no layout checks. The corpus appears by one
# rename, so a reader sees all of it or none.
download_corpus() {
    require_tool sha256sum
    require_tool tar

    if verify_corpus; then
        echo "computation-hash corpus is ready: $corpus"
        return
    fi
    script/fetch.sh "$release_url" "$archive_sha256" "$archive"

    staging=$(mktemp -d "${release_cache}/.corpus.XXXXXX")
    tar --no-same-owner --no-same-permissions \
        -xzf "$archive" -C "$staging" --strip-components=1
    printf '%s %s\n' "$release_version" "$archive_sha256" > "$staging/.release"
    rm -rf -- "$corpus"
    mv -- "$staging" "$corpus"
    staging=

    if ! verify_corpus; then
        echo "error: failed to publish a verified computation-hash corpus" >&2
        exit 1
    fi
    echo "computation-hash corpus is ready: $corpus"
}

require_corpus() {
    require_tool cargo
    require_tool sha256sum

    if ! verify_corpus; then
        echo "error: the verified computation-hash corpus is not available" >&2
        echo "fix: script/computation-hash-corpus.sh download" >&2
        exit 1
    fi
}

run_corpus_test() {
    local test_name="$1"

    CARTESI_COMPUTATION_HASH_CORPUS_PATH="$corpus" \
        cargo test --locked -p cartesi-sling-node \
            --test engine_machine \
            "$test_name" \
            -- --ignored --exact --nocapture
}

test_cli() {
    require_corpus
    require_tool cartesi-machine
    run_corpus_test computation_hash_corpus_cli_matches_release_manifest
}

test_dave() {
    require_corpus
    run_corpus_test computation_hash_corpus_dave_matches_release_manifest
}

test_corpus() {
    test_cli
    test_dave
}

[ "$#" -eq 1 ] || usage

case "$1" in
    download)
        download_corpus
        ;;
    test-cli)
        test_cli
        ;;
    test-dave)
        test_dave
        ;;
    test)
        test_corpus
        ;;
    *)
        usage
        ;;
esac
