#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dave-solc-linux-arm64-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    echo "solc-linux-arm64 test: $*" >&2
    exit 1
}

# A repository of its own: the script under test, a fetch that writes a
# stand-in compiler instead of downloading, and both projects' pins.
readonly repo="${fixture}/repo" bin="${fixture}/bin"
mkdir -p "${repo}/script" "${repo}/prt/contracts" \
    "${repo}/cartesi-rollups/contracts" "$bin"
cp "${script_dir}/../solc-linux-arm64.sh" "${repo}/script/"
readonly solc="${repo}/script/solc-linux-arm64.sh"
version="$(sed -n 's/^readonly version=//p' "$solc")"
[ -n "$version" ] || fail "cannot read the script's pinned version"
pin() {
    printf 'solc_version = "%s"\n' "$2" >"${repo}/$1/foundry.toml"
}
pin prt/contracts "$version"
pin cartesi-rollups/contracts "$version"

cat >"${repo}/script/fetch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"${FETCH_LOG}"
mkdir -p -- "$(dirname -- "$3")"
printf '#!/bin/sh\necho "Version: %s+commit.stand-in"\n' "${STAND_IN_VERSION}" >"$3"
EOF
chmod +x "${repo}/script/fetch.sh"
export FETCH_LOG="${fixture}/fetch.log" STAND_IN_VERSION="$version"
: >"$FETCH_LOG"

# uname answers for the platform under test.
cat >"${bin}/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo "$FAKE_SYSTEM" ;; -m) echo "$FAKE_MACHINE" ;; esac
EOF
chmod +x "${bin}/uname"
export PATH="${bin}:${PATH}"

on() {
    FAKE_SYSTEM=$1 FAKE_MACHINE=$2 HOME=$3 XDG_DATA_HOME=${4:-} "$solc" "${@:5}"
}

# Every platform svm serves is left alone, by both actions.
home="${fixture}/home-served"
mkdir -p "$home"
for platform in "Linux x86_64" "Darwin arm64" "Darwin x86_64"; do
    # shellcheck disable=SC2086
    on $platform "$home" "" install >/dev/null || fail "install failed on $platform"
    # shellcheck disable=SC2086
    on $platform "$home" "" verify >/dev/null || fail "verify failed on $platform"
done
[ ! -s "$FETCH_LOG" ] || fail "fetched on a platform svm serves"
[ -z "$(ls -A "$home")" ] || fail "wrote under HOME on a platform svm serves"

# Linux arm64, no svm directory and no XDG data directory: svm uses ~/.svm.
home="${fixture}/home-bare"
mkdir -p "$home"
if on Linux aarch64 "$home" "" verify 2>/dev/null; then
    fail "verified a compiler that is not installed"
fi
on Linux aarch64 "$home" "" install >/dev/null || fail "install failed"
dest="${home}/.svm/${version}/solc-${version}"
[ -x "$dest" ] || fail "did not install an executable at ~/.svm"
grep -Fq "/linux-arm64/solc-linux-arm64-v${version}+commit." "$FETCH_LOG" ||
    fail "did not fetch the official Linux arm64 build"
# The stand-in is not the pinned bytes, so verify must still refuse it.
if on Linux aarch64 "$home" "" verify 2>/dev/null; then
    fail "verified a file that does not match the pinned SHA-256"
fi

# An XDG data directory without ~/.svm: svm uses the data directory.
home="${fixture}/home-xdg"
mkdir -p "${home}/.local/share"
on Linux aarch64 "$home" "" install >/dev/null || fail "install failed (XDG default)"
[ -x "${home}/.local/share/svm/${version}/solc-${version}" ] ||
    fail "did not follow svm into ~/.local/share/svm"
[ ! -e "${home}/.svm" ] || fail "created ~/.svm beside the XDG data directory"

home="${fixture}/home-xdg-set"
mkdir -p "$home" "${fixture}/data"
on Linux aarch64 "$home" "${fixture}/data" install >/dev/null ||
    fail "install failed (XDG_DATA_HOME)"
[ -x "${fixture}/data/svm/${version}/solc-${version}" ] ||
    fail "did not follow svm into XDG_DATA_HOME"

# An existing ~/.svm wins over the data directory.
home="${fixture}/home-both"
mkdir -p "${home}/.svm" "${home}/.local/share"
on Linux aarch64 "$home" "" install >/dev/null || fail "install failed (both)"
[ -x "${home}/.svm/${version}/solc-${version}" ] ||
    fail "did not prefer an existing ~/.svm"

# A compiler that does not run as the pinned version is refused.
home="${fixture}/home-wrong"
mkdir -p "$home"
if (
    export STAND_IN_VERSION=0.0.1
    on Linux aarch64 "$home" "" install >/dev/null 2>&1
); then
    fail "accepted a compiler reporting another version"
fi

# A project pin the script does not follow fails on every platform, before
# anything is fetched or written.
: >"$FETCH_LOG"
home="${fixture}/home-drift"
mkdir -p "$home"
pin cartesi-rollups/contracts 9.9.9
for platform in "Linux x86_64" "Linux aarch64" "Darwin arm64"; do
    for action in install verify; do
        # shellcheck disable=SC2086
        if on $platform "$home" "" "$action" >/dev/null 2>"${fixture}/stderr"; then
            fail "$action passed on $platform with a drifted pin"
        fi
        grep -Fq "pins solc 9.9.9" "${fixture}/stderr" ||
            fail "$action on $platform did not name the drifted pin"
    done
done
[ ! -s "$FETCH_LOG" ] || fail "fetched with a drifted pin"
[ -z "$(ls -A "$home")" ] || fail "wrote under HOME with a drifted pin"

echo "solc-linux-arm64 tests passed"
