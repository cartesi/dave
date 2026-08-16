#!/usr/bin/env bash
# Not set -e: every check must run; failures are counted, not fatal.
set -u

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CDPATH= cd -- "$repo_root" || exit 2

fails=0; warns=0
diagnosed_components=""
checker_failures=""
ok()   { printf '  ok      %s\n' "$1"; }
miss() { printf '  MISSING %s\n' "$1"; printf '          fix: %s\n' "$2"; fails=$((fails+1)); }
warn() { printf '  warn    %s\n' "$1"; printf '          %s\n' "$2"; warns=$((warns+1)); }

run_component() {
  local label=$1
  local dir=$2
  local script=$3
  local component_status

  (
    CDPATH= cd -- "$dir" || exit 2
    "$script"
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
for tool in git cargo forge anvil cast lua5.4 luacheck jq sqlite3 \
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
if command -v docker > /dev/null; then ok "docker"; else
  warn "docker not on PATH" "needed only for the honeypot image and dockerized workflows"; fi
if command -v xgenext2fs > /dev/null; then ok "xgenext2fs"; else
  warn "xgenext2fs not on PATH" \
    "needed only to build the honeypot image (its project generates rootfs from a tarball with it)"; fi
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
for tool in cartesi-machine cartesi-machine-stored-hash; do
  if command -v "$tool" > /dev/null; then ok "$tool"; else
    miss "$tool not on PATH" "install the Cartesi Machine (nix devshell has it), needed to build/run test programs"; fi
done
}

check_rust_build_inputs() {
echo "rust build inputs"
run_component "machine" machine ./script/doctor.sh
run_component "prt-contracts" prt/contracts ./script/doctor.sh
run_component "rollups-contracts" cartesi-rollups/contracts ./script/doctor.sh
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

check_toolchain
check_rust_build_inputs
check_e2e_test_inputs

echo
doctor_status=0
if [ "$fails" -gt 0 ] || [ -n "$diagnosed_components" ]; then
  doctor_status=1
fi
if [ -n "$checker_failures" ]; then
  doctor_status=2
fi

case "$doctor_status" in
  0) echo "doctor: healthy ($warns root warning(s)). setup docs: docs/build-system.md" ;;
  1) echo "doctor: setup required ($fails root problem(s), $warns root warning(s)). setup docs: docs/build-system.md" ;;
  2) echo "doctor: checker failure ($fails root problem(s), $warns root warning(s)). setup docs: docs/build-system.md" ;;
esac
if [ -n "$diagnosed_components" ]; then
  echo "doctor: diagnosed component issue(s): $diagnosed_components"
fi
if [ -n "$checker_failures" ]; then
  echo "doctor: component checker failure(s): $checker_failures"
fi
exit "$doctor_status"
