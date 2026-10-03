#!/usr/bin/env bash
# Remove the entries under a Foundry project's dependencies/ that its
# soldeer.lock does not name. Soldeer installs `<name>-<version>` and keeps
# the old directory after a version bump. The leftover is no compiler input
# (remappings are versioned), but it enters every digest taken over
# dependencies/: the gas measurement's pin and the devnet fingerprint. The
# prune only deletes, so it works offline.
set -euo pipefail

cd "${1:-.}"
[ -d dependencies ] || exit 0

keep="$(awk -F'"' '/^name = /{name=$2} /^version = /{print name "-" $2}' soldeer.lock)"
if [ -z "$keep" ]; then
    echo "soldeer-prune: no dependency parsed from $(pwd -P)/soldeer.lock; not pruning" >&2
    exit 1
fi
# A locked name that is not installed means the parse disagrees with
# soldeer's layout; deleting on that guess could take every dependency.
while IFS= read -r name; do
    if [ ! -d "dependencies/$name" ]; then
        echo "soldeer-prune: locked dependency $name is not installed; not pruning" >&2
        exit 1
    fi
done <<<"$keep"

for entry in dependencies/*; do
    [ -e "$entry" ] || continue
    if ! grep -Fxq -- "${entry#dependencies/}" <<<"$keep"; then
        echo "soldeer-prune: removing $entry (not in soldeer.lock)"
        rm -rf -- "$entry"
    fi
done
