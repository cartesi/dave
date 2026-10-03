#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
prune="${script_dir}/../soldeer-prune.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dave-soldeer-prune-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    echo "soldeer-prune test: $*" >&2
    exit 1
}

cat >"${fixture}/soldeer.lock" <<'EOF'
[[dependencies]]
name = "@openzeppelin-contracts"
version = "5.5.0"
url = "https://example.invalid/oz.zip"

[[dependencies]]
name = "cartesi-rollups-contracts"
version = "3.0.0-alpha.10"
url = "https://example.invalid/rollups.zip"
EOF
mkdir -p \
    "${fixture}/dependencies/@openzeppelin-contracts-5.5.0" \
    "${fixture}/dependencies/cartesi-rollups-contracts-3.0.0-alpha.10/dependencies/forge-std-1.9.6" \
    "${fixture}/dependencies/cartesi-rollups-contracts-3.0.0-alpha.9/src"
touch "${fixture}/dependencies/cartesi-rollups-contracts-3.0.0-alpha.9/src/Old.sol"
lock_before="$(cat "${fixture}/soldeer.lock")"

"$prune" "$fixture" >/dev/null
[ ! -e "${fixture}/dependencies/cartesi-rollups-contracts-3.0.0-alpha.9" ] ||
    fail "kept a version the lock does not name"
[ -d "${fixture}/dependencies/@openzeppelin-contracts-5.5.0" ] ||
    fail "removed a locked dependency"
[ -d "${fixture}/dependencies/cartesi-rollups-contracts-3.0.0-alpha.10/dependencies/forge-std-1.9.6" ] ||
    fail "removed a locked dependency's own dependencies"
[ "$(cat "${fixture}/soldeer.lock")" = "$lock_before" ] || fail "changed the lock"

# A lock naming a dependency that is not installed is a parse it cannot
# trust: refuse, and delete nothing.
mkdir -p "${fixture}/dependencies/forge-std-1.9.5"
rm -rf "${fixture}/dependencies/@openzeppelin-contracts-5.5.0"
if "$prune" "$fixture" 2>/dev/null; then
    fail "pruned although a locked dependency is missing"
fi
[ -d "${fixture}/dependencies/forge-std-1.9.5" ] || fail "deleted after refusing"

echo "soldeer-prune tests passed"
