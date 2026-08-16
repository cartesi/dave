# Emulator constants benchmark

This is the independent emulator-level reference harness for exploring PRT
tournament geometry. The Rust node's `just measure-constants` remains the
current generator for `docs/measurements/constants.md`; use this harness as a
second measurement method when changing the deployed geometry.

The harness uses the checksum-pinned `test/programs/linux.bin` and
`rootfs.ext2`. For every selected workload it starts stress-ng, waits until its
worker exists, and reaches a manual-yield readiness marker. It releases that
marker, runs a fixed untimed warmup, and stores the active machine used by every
timed phase. Linux boot, process startup, and the warmup are therefore excluded
from the timings. Stress-ng deliberately has no guest timeout: every host-side
sample is bounded, and an indefinitely live guest keeps later replayed phases
on the same workload. The temporary fixtures are removed after each workload
and are not part of the persistent test-program lifecycle.

The curated workloads exercise different instruction and memory behavior:

```text
nop crypt heapsort tsearch memthrash matrix-3d tree tlb-shootdown malloc randlist
```

List them or cheaply validate their active, warmed state without running the
multi-minute benchmark:

```bash
just list-workloads
just check-fixtures             # all workloads
just check-fixtures nop malloc  # selected workloads
```

Benchmark runs require an explicit selection:

```bash
just benchmark nop
just benchmark crypt heapsort
just benchmark all
```

Run these commands from this directory, or pass its Justfile with
`just -f prt/measure_constants/justfile ...` from the repository root. The
default sample is 120 seconds per timed phase, the inner commitment budget is
30 minutes, and the accepted root slowdown is 10. Override them explicitly
when studying another policy:

```bash
DAVE_SAMPLE_SECONDS=300 \
DAVE_INNER_TIMEOUT_MINUTES=60 \
DAVE_ROOT_SLOWDOWN=5 \
just benchmark matrix-3d
```

Results are evidence, not deployable constants by themselves. Record the
workload selection, emulator version, hardware, timing policy, and complete
output whenever a result informs `ArbitrationConstants`.
