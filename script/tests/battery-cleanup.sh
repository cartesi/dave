#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH= cd -- "${script_dir}/../.." && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dave-battery-cleanup.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/e2e/scenarios" "$fixture/bin"
cp "$repo_root/test/e2e/rollups/battery.sh" "$fixture/e2e/battery.sh"

cat >"$fixture/bin/just" <<'EOF'
#!/usr/bin/env bash
set -eu
: "${TEST_INSTANCE:?missing TEST_INSTANCE}"
mkdir -p \
    "_state-${TEST_INSTANCE}" \
    "_oracle-${TEST_INSTANCE}" \
    "_machine_scratch-${TEST_INSTANCE}"
printf 'node log\n' >"dave-${TEST_INSTANCE}.log"
EOF
chmod +x "$fixture/bin/just"

(
    CDPATH= cd -- "$fixture/e2e"
    PATH="$fixture/bin:$PATH" \
        BASE_PORT=24000 \
        DAVE_BATTERY_CLEAN_STATE=1 \
        /bin/bash ./battery.sh 2 >/dev/null
)

if find "$fixture/e2e" -maxdepth 1 \
    \( -name '_state-*' -o -name '_oracle-*' -o -name '_machine_scratch-*' \) \
    -print -quit | grep -q .; then
    echo "error: CI battery retained per-scenario machine state" >&2
    exit 1
fi

[[ "$(wc -l <"$fixture/e2e/_battery/results.txt" | tr -d ' ')" -eq 25 ]]
[[ "$(find "$fixture/e2e" -maxdepth 1 -name 'dave-*.log' | wc -l | tr -d ' ')" -eq 25 ]]

echo "battery cleanup tests: passed"
