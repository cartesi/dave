#!/usr/bin/env bash
# Not set -e: every check must run; failures are counted, not fatal.
set -u

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CDPATH= cd -- "$repo_root" || exit 2

usage() {
  echo "usage: script/doctor.sh [base|e2e|all]" >&2
  exit 2
}

scope=${1:-base}
[ "$#" -le 1 ] || usage
case "$scope" in
  base|e2e|all) ;;
  *) usage ;;
esac
readonly scope

fails=0; warns=0
diagnosed_components=""
checker_failures=""
ok()   { printf '  ok      %s\n' "$1"; }
miss() { printf '  MISSING %s\n' "$1"; printf '          fix: %s\n' "$2"; fails=$((fails+1)); }
warn() { printf '  warn    %s\n' "$1"; printf '          %s\n' "$2"; warns=$((warns+1)); }

run_component() {
  local label=$1
  local dir=$2
  local component_status
  shift 2

  (
    CDPATH= cd -- "$dir" || exit 2
    "$@"
  )
  component_status=$?

  case "$component_status" in
    0) ;;
    1)
      if [ -n "$diagnosed_components" ]; then
        diagnosed_components="$diagnosed_components, "
      fi
      diagnosed_components="$diagnosed_components$label"
      ;;
    *)
      if [ -n "$checker_failures" ]; then
        checker_failures="$checker_failures, "
      fi
      checker_failures="$checker_failures$label"
      ;;
  esac
}

check_toolchain() {
echo "toolchain (nix users: 'direnv allow' provides all of these)"
for tool in git cargo forge lua5.4 luacheck jq sqlite3 \
    cartesi-machine cartesi-machine-stored-hash \
    wget curl realpath sha256sum sort; do
  if command -v "$tool" > /dev/null; then ok "$tool"; else
    miss "$tool not on PATH" "install it (see README.md requirements)"; fi
done
if command -v make >/dev/null; then
  make_version=$(make --version 2>/dev/null | sed -n '1p')
  case "$make_version" in
    "GNU Make "*) ok "$make_version" ;;
    *) miss "GNU make not available" \
      "install GNU make (the nix devshell provides it)" ;;
  esac
else
  miss "GNU make not available" \
    "install GNU make (the nix devshell provides it)"
fi
if command -v sort >/dev/null; then
  sort_version=$(sort --version 2>/dev/null | sed -n '1p')
  case "$sort_version" in
    *"GNU coreutils"*) ok "$sort_version" ;;
    *) miss "GNU sort not available" \
      "install GNU coreutils (the nix devshell provides it)" ;;
  esac
fi
if command -v docker > /dev/null; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon"
  else
    miss "docker daemon is unavailable" "start Docker (Rust KMS tests use it)"
  fi
else
  miss "docker not on PATH" "install and start Docker (Rust KMS tests use it)"
fi
# Forge formatter heuristics drift across releases; a local/CI
# version split fails CI fmt with no local reproduction. Compare
# against the root pin that CI also consumes.
if command -v forge > /dev/null; then
  ci_pin=$(sed -n 's/^FOUNDRY_VERSION := "\([0-9][0-9.]*\)"$/\1/p' justfile | head -1)
  local_forge=$(forge --version 2>/dev/null | sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' | head -1)
  if [ -n "$ci_pin" ] && [ -n "$local_forge" ]; then
    if [ "$local_forge" = "$ci_pin" ]; then
      ok "forge $local_forge matches the CI pin"
    else
      warn "forge $local_forge != CI pin v$ci_pin" \
        "formatter output will differ from CI; align the devshell and FOUNDRY_VERSION in the root justfile"
    fi
  fi
fi
}

check_e2e_tools() {
echo "e2e toolchain"
for tool in anvil cast cartesi-machine cartesi-machine-stored-hash; do
  if command -v "$tool" > /dev/null; then ok "$tool"; else
    miss "$tool not on PATH" "install it (the nix devshell provides the E2E toolchain)"; fi
done
if command -v xgenext2fs > /dev/null; then ok "xgenext2fs"; else
  warn "xgenext2fs not on PATH" "needed to rebuild the Docker-heavy Honeypot image"; fi
}

check_rust_build_inputs() {
echo "rust build and standard-test inputs"
run_component "machine" machine ./script/doctor.sh
run_component "prt-contracts" prt/contracts \
  "$repo_root/script/contracts-doctor.sh" prt
run_component "rollups-contracts" cartesi-rollups/contracts \
  "$repo_root/script/contracts-doctor.sh" rollups
run_component "programs" test/programs ./script/doctor.sh standard
}

check_e2e_test_inputs() {
run_component "programs" test/programs ./script/doctor.sh
run_component "rollups-e2e" test/e2e/rollups ./script/doctor.sh
# Historic leak class (806 GB found 2026-07-11): tests that
# tempdir().keep() into the system TMPDIR leave orphans nothing
# sweeps. Test scratch belongs under target/ (CARGO_TARGET_TMPDIR).
if command -v getconf > /dev/null; then
  sys_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
  if [ -n "$sys_tmp" ]; then
    tmp_litter=$(du -sm "$sys_tmp".tmp* 2>/dev/null | awk '{sum+=$1} END {printf "%d", sum}')
    if [ "${tmp_litter:-0}" -gt 10000 ]; then
      warn "system TMPDIR holds ${tmp_litter} MB of .tmp* orphans" \
        "leaked test scratch; sweep with: rm -rf \"$sys_tmp\".tmp*"
    fi
  fi
fi
}

case "$scope" in
  base)
    check_toolchain
    check_rust_build_inputs
    ;;
  e2e)
    check_e2e_tools
    check_e2e_test_inputs
    ;;
  all)
    check_toolchain
    check_rust_build_inputs
    check_e2e_tools
    check_e2e_test_inputs
    ;;
esac

echo
doctor_status=0
if [ "$fails" -gt 0 ] || [ -n "$diagnosed_components" ]; then
  doctor_status=1
fi
if [ -n "$checker_failures" ]; then
  doctor_status=2
fi

case "$doctor_status" in
  0) echo "doctor ($scope): healthy ($warns root warning(s)). setup docs: docs/build-system.md" ;;
  1) echo "doctor ($scope): setup required ($fails root problem(s), $warns root warning(s)). setup docs: docs/build-system.md" ;;
  2) echo "doctor ($scope): checker failure ($fails root problem(s), $warns root warning(s)). setup docs: docs/build-system.md" ;;
esac
if [ -n "$diagnosed_components" ]; then
  echo "doctor: diagnosed component issue(s): $diagnosed_components"
fi
if [ -n "$checker_failures" ]; then
  echo "doctor: component checker failure(s): $checker_failures"
fi
exit "$doctor_status"
