# Tooling footguns

Status: BACKLOG (created 2026-09-29). An inventory of repository tooling
friction observed while landing the two-level sling stack, kept so a later
cleanup campaign starts from evidence instead of memory. It is orthogonal to
the dispute work and not scheduled.

The repository's doctrine applies: fix a trap in the tooling, not in the
docs, and make every failure name its fix. Order the work by cost times
frequency; the counts below come from one working session (about 400 shell
commands, 23 e2e runs, 21 devnet builds).

## Observed

- One devnet bundle and one anvil port serve both geometries. Every two-level
  e2e run rebuilds the bundle as two-level and afterwards restores the
  canonical one, which accounts for most of the session's devnet builds, and
  two jobs that both start anvil collide on its port ("Address already in
  use"). Candidate fix: per-geometry bundle directories selected by
  `DEVNET_GEOMETRY`, and a lock around every recipe that starts anvil.
- The toolchain (forge, the `cartesi-machine` CLI, the pinned emulator
  library) is not on the bare `PATH`. Commands run through
  `nix develop <flake> --command bash -c '...'`, where nested quoting
  misfires (an unquoted heredoc once swallowed a backticked path). Candidate
  fix: recipes that enter the devshell themselves, or a doctor check that
  names the fix.
- E2E verdicts depend on the node's speed. The e2e node is a debug build, and
  the first two-level smoke failed because the node lost a dispute by
  timeout; it read as a correctness failure. Candidate fix: a release-profile
  node for dispute-heavy scenarios, and a harness message that separates
  "lost by timeout" from "lost on a proof".
- Honeypot's machine image embeds devnet deployment addresses, so any change
  to contract bytecode makes it stale. The preflight catches it, but nothing
  rebuilds it, and `bootstrap-worktree` does not build it at all. Candidate
  fix: rebuild it on demand when its fingerprint lags the devnet.
- The node's unit tests fail intermittently on an emulator file lock:
  v0.21.0 opens stored files without O_CLOEXEC, so an anvil child spawned by
  a parallel test inherits the lock (upstream fix 642703cfb, unreleased). A
  separate task is open for a test-side mitigation.
- Script portability traps: macOS ships bash 3.2, where `set -u` fails on an
  empty array (hit in `devnet-fingerprint.sh`), and `forge script` resolves a
  script path against the working directory, not `--root`.
- The v0.21.0 CLI's default revert mode (`fork`) needs a machine server; the
  e2e reference gate runs it in `stored` mode on a disposable clone.
- Review hygiene: `git diff` omits untracked files, so a saved diff handed to
  reviewers missed two new files. Save review diffs with untracked files
  included (`git add -N` first, or diff against an index that has them).

## Session habits (not repository defects)

- Start session worktrees with `just bootstrap-worktree`; doing its steps by
  hand cost time.
- Run independent validations in one sequential background job with explicit
  exit codes (`just logged`), and never two jobs that start anvil at once.
