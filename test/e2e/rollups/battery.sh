#!/usr/bin/env bash
# The full e2e battery, parallel: one TEST_INSTANCE (anvil port +
# suffixed working-dir singletons) per scenario, LANES at a time, so
# wall clock is the max of the set instead of the sum. Chaos runs at
# a fixed seed: the battery is a regression net, seed exploration is
# a separate exercise. Instance dirs and logs are left in place for
# forensics; sweep them once the results are read.
#
#   LANES=5 BASE_PORT=8601 ./battery.sh
#
# Results land in _battery/results.txt as "<program> <scenario> rc secs";
# per-scenario stdout in _battery/<program>-<scenario>.log, node logs in
# dave-<port>.log. Exit code is the number of failed scenarios.
set -u
cd "$(dirname "$0")"

# LANES as first arg or env (the arg survives direnv exec, which
# swallows leading VAR=... assignments).
LANES=${1:-${LANES:-5}}
BASE_PORT=${BASE_PORT:-8601}
OUT=_battery
mkdir -p "$OUT"
: > "$OUT/results.txt"

# Power provenance: sleep-tainted timings look like uniform dispute
# slowdowns and once burned a whole diagnosis session (test-harness.md
# addendum, 2026-07-10). caffeinate holds the box awake below, but
# the record travels with the results either way.
if command -v pmset > /dev/null; then
    power_start=$(pmset -g batt | head -1)
    echo "power at start: $power_start" > "$OUT/power.txt"
    case "$power_start" in
        *Battery*) echo "[battery] WARNING: on battery power - timings may be sleep-tainted (passes remain trustworthy)" ;;
    esac
fi

SCENARIOS=(
    "echo simple"
    "echo multi_sybil"
    "echo chaos"
    "echo kill_catchup"
    "echo kill_catchup_batched"
    "echo kill_settle"
    "echo kill_commitment_build"
    "echo kill_mid_match"
    "echo kill_join"
    # Retained timeout-alignment boundary evidence. These scenarios
    # drive block numbers through the sender, so parallel lanes cannot
    # disturb them; measured ~2 min each (2026-07-25).
    "echo sealed_leaf_timeout_winner"
    "echo sealed_leaf_timeout_both"
    "honeypot deposit_withdrawal"
    "honeypot simple_no_input"
    "honeypot stf_all"
    "honeypot big_input"
    "honeypot gc_match"
    "honeypot gc_tournament"
    "honeypot bad_commitment"
    "yield simple_no_input"
    "yield stf_all"
    "yield stf_revert"
    "yield big_input"
    "yield gc_match"
    "yield gc_tournament"
    "yield bad_commitment"
)

# Every scenarios/*.lua must be wired into SCENARIOS under some
# program, or listed here with its reason: an unwired net rots in the
# dark (stf_revert was dark from birth; docs/test-harness.md).
EXCLUDED_SCENARIOS=(
)
for f in scenarios/*.lua; do
    c=$(basename "$f" .lua)
    wired=0
    for s in "${SCENARIOS[@]}"; do
        if [ "${s#* }" = "$c" ]; then wired=1; break; fi
    done
    if [ "$wired" -eq 0 ]; then
        case " ${EXCLUDED_SCENARIOS[*]:-} " in
            *" $c "*) ;;
            *) echo "[battery] WARNING: scenarios/$c.lua is wired into no battery scenario (add it to SCENARIOS, or to EXCLUDED_SCENARIOS with its reason)" ;;
        esac
    fi
done

run_one() {
    local index=$1 program=$2 scenario=$3
    local port=$((BASE_PORT + index))
    local start=$SECONDS
    TEST_INSTANCE=$port CHAOS_SEED=${CHAOS_SEED:-1} \
        just test "$program" "$scenario" > "$OUT/$program-$scenario.log" 2>&1
    local rc=$?
    echo "$program $scenario $rc $((SECONDS - start)) $(date +%H:%M:%S)" >> "$OUT/results.txt"
    echo "[battery] $program $scenario rc=$rc $((SECONDS - start))s"
    return "$rc"
}
export -f run_one
export BASE_PORT OUT

# An unattended battery on a macOS laptop dies of idle sleep, not of
# bugs: the 2026-07-10 verification run froze whole lanes for the
# exact durations pmset logged as Deep Idle, and the wall-clock
# scenario deadline then killed the longest waits. caffeinate blocks
# idle sleep (empirically also on battery power) and holds only for
# the run; it cannot block lid-close sleep, which is what the
# tripwire below is for.
AWAKE=""
command -v caffeinate > /dev/null && AWAKE="caffeinate -is"
if command -v pmset > /dev/null && pmset -g batt 2>/dev/null | grep -q "Battery Power"; then
    echo "[battery] note: on battery power; idle sleep is held off, but a closed lid still sleeps the run"
fi
RUN_STARTED=$(date "+%Y-%m-%d %H:%M:%S")

for i in "${!SCENARIOS[@]}"; do
    echo "$i ${SCENARIOS[$i]}"
done | $AWAKE xargs -P "$LANES" -L1 bash -c 'run_one "$@"' _
failures=$(awk '$3 != 0' "$OUT/results.txt" | wc -l | tr -d ' ')

# Sleep tripwire: a nap mid-run stretches every wall time and can
# push slow scenarios into the deadline; label the results rather
# than let a tainted run pass for a slow one.
if command -v pmset > /dev/null; then
    naps=$(pmset -g log 2>/dev/null | grep "Entering Sleep" \
        | awk -v s="$RUN_STARTED" '{ts = $1 " " $2} ts >= s' | wc -l | tr -d ' ')
    if [ "$naps" -gt 0 ]; then
        echo "SLEEP-TAINTED: $naps sleep(s) during the run; timings and deadline failures are unreliable" \
            | tee -a "$OUT/results.txt"
    fi
fi

if command -v pmset > /dev/null; then
    echo "power at end: $(pmset -g batt | head -1)" >> "$OUT/power.txt"
fi

echo "[battery] done: $(wc -l < "$OUT/results.txt" | tr -d ' ') scenarios, $failures failed"
sort -k4 -n -r "$OUT/results.txt"
exit "$failures"
