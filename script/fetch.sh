#!/usr/bin/env bash
# Download URL to DEST unless DEST already has the pinned SHA-256. DEST is
# replaced only by a verified download, so it is never half-written.
set -euo pipefail

if (($# != 3)) || [[ ! "$2" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'usage: script/fetch.sh URL SHA256 DEST\n' >&2
    exit 2
fi
readonly url=$1 sha=$2 dest=$3

# Compare digests by hand: macOS sha256sum -c passes a malformed line.
matches() {
    local digest
    digest="$(sha256sum -- "$1")" && [[ "${digest%% *}" == "$sha" ]]
}

if [[ -f "$dest" ]] && matches "$dest"; then
    printf 'fetch: %s is cached\n' "$dest"
    exit 0
elif [[ -e "$dest" && ! -f "$dest" ]]; then
    printf 'error: %s exists and is not a regular file\n' "$dest" >&2
    exit 2
fi
mkdir -p -- "$(dirname -- "$dest")"
temporary="$(mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").fetch.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$temporary" "$url"
if ! matches "$temporary"; then
    printf 'error: %s does not match SHA-256 %s\n' "$url" "$sha" >&2
    exit 1
fi
chmod 0644 "$temporary"
mv -f -- "$temporary" "$dest"
printf 'fetch: downloaded %s\n' "$dest"
