# External contracts audit: readiness

Status: open, written 2026-10-02 as a brief for a follow-up; linked from
[`docs/todo.md`](../todo.md). No audit firm, date, scope or target commit is
recorded anywhere yet. When the audit is scheduled, the decisions below move
into todo.md and the living docs, and this file is deleted. Line numbers are
at the commit that added this file; re-check them.

## Candidate scope

- `prt/contracts/src/`: `Tournament` and its libraries,
  `MultiLevelTournamentFactory`, `CanonicalTournamentParametersProvider`,
  `ClockBudgets`, `ArbitrationConstants`, and `CartesiStateTransition`.
- `cartesi-rollups/contracts/src/`: `DaveConsensus` and `DaveAppFactory`
  with their interfaces.
- The deployment scripts: `prt/contracts/script/Deployment.s.sol` and
  `BaseDeploymentScript.sol`; `cartesi-rollups/contracts/script/`
  `Deployment.s.sol`, `deploy.sh`, `deploy-mainnets.sh`, `deploy-testnets.sh`
  and `deploy-experimental.sh`.
- `machine/step` (the generated Solidity uarch, solidity-step v0.15.0): in
  scope, or trusted as upstream with `CartesiStateTransition` as the seam
  (an open question).

Out of scope: everything under `test/`, including `test/devnet/` (a
devnet-only script behind a `NotADevnet` guard) and the test-only
`TableTournamentParametersProvider` and `TournamentParameterTableValidator`;
the off-chain clients; the rollups-contracts dependency (`Application`,
`InputBox`, 3.0.0-alpha.10), which is upstream.

## Trust boundaries to hand the auditor

- The dispute adversary is permissionless and fully malicious
  (dimensioning.md, "The trust boundary").
- The application developer is trusted to keep input-reachable behavior
  disputable, and authors the template machine (dimensioning.md; the
  per-input compute contract).
- The deployer's parameter table is trusted: production validates nothing
  on chain beyond code presence and a nonzero allowance and block time
  (below), and a provider's table must be validated before use and stay
  stable for its factory's lifetime (dispute-game.md:608-610).
- The base layer may censor the honest party for at most `C` in total per
  root dispute; chain support is stated in prt/contracts/AGENTS.md, "Trust
  boundary and assumptions".
- `machine/step` and the emulator agree on the uarch transition;
  `CM_MARCHID` names the release they agree on (computation-hash.md).
- `InputBox` integrity (cartesi-rollups/contracts/AGENTS.md).
- Foreclosure is the application layer's backstop, by its guardian;
  sentries only shorten the staging wait (epoch-lifecycle.md, "Consensus
  layer").

## Explicit non-claims to hand the auditor

From prt/contracts/AGENTS.md ("Explicit non-claims"),
cartesi-rollups/contracts/AGENTS.md ("Explicit non-claims") and
dispute-game.md:

- No general recursive liveness proof: neither termination nor a delay
  bound, and R19 claims neither. Honest survival under `C`, and a correct
  winner if the root finishes, are open until R19 lands
  ([r19-honest-survival.md](r19-honest-survival.md)).
- The accepted CF-01 leaf handover limitation (dispute-game.md, "Resolution
  and winner re-entry").
- A well-formed table does not prove that clients build the same
  commitments.
- Non-Ethereum time and fee conformance is not established.
- The leaf-proof refund is not a universal proof-class gas ceiling.
- Sentry agreement does not prove a result correct; there is no on-chain
  recovery for a lost sentry-manager key.
- More than 2^24 inputs in one epoch is out of model (dimensioning.md).

## Pre-audit items

Each is a script, test, CI or docs change except where noted; all can land
before the freeze.

1. R19, the honest-survival model ([r19-honest-survival.md](r19-honest-survival.md)).
   A counterexample would be a bytecode change, so it must come before the
   freeze.
2. Contract code shaped for tests. `_getClockModel(Seconds commitmentBudget)`
   in `prt/contracts/script/Deployment.s.sol:226` takes a parameter only the
   devnet script varies (`test/devnet/DevnetGeometryDeployment.s.sol:55`);
   production passes `ArbitrationConstants.COMMITMENT_BUDGET` (:208-210).
   Declare `test/devnet/` out of scope; collapse the parameter when
   `DEVNET_GEOMETRY` retires, unless a test-shape profile keeps it.
3. Geometry validation is test-only. `MultiLevelTournamentFactory`'s
   constructor checks only that its dependencies have code
   (`src/tournament/factories/MultiLevelTournamentFactory.sol:36-46`); the
   canonical provider rejects only a zero root allowance or block time. The
   whole-table validator lives in `test/fixtures/`. Its canonical test,
   `testCurrentCanonicalTableIsValid`
   (`test/config/TournamentParameterTableValidator.t.sol`), validates the
   canonical provider's own rows at Ethereum's 12 s blocks, with one week of
   censorship and with none, where the root allowance must hold exactly the
   pending delegations, so its refill check runs with the real `T`;
   `testCanonicalProviderRowsAndTiling` compares the provider with
   `ClockBudgets` itself. State the table as trusted configuration. A root
   allowance short by one refill is a fixed loss of `T + 2G` (tolerance
   falls from `C` to `C - (T + 2G)`), decisive only near `C = 0`; an
   accumulating drain needs per-row or understated budgets.
4. The deployment path, and a runbook it lacks. `deploy.sh` runs three Forge
   scripts in order (PRT, the rollups-contracts dependency, Dave); every
   address is CREATE2 with a zero salt over the full initcode
   (`prt/contracts/script/BaseDeploymentScript.sol:53-64`); Dave's script
   finds the PRT factory by name
   (`cartesi-rollups/contracts/script/Deployment.s.sol:17`); release CI only
   simulates deployment and publishes the addresses as release assets, one
   for Ethereum and Sepolia and one for the experimental chains
   (`.github/workflows/build.yml:422-431`). `docs/runbooks/` holds only the
   gas runbook. Write a deployment runbook: chains, parameters, broadcast,
   address verification against the release asset, post-deploy checks (a
   node started against the deployment checks geometry and `CM_MARCHID`).
5. The `CM_MARCHID` literal. `CartesiStateTransition.sol:35-37` hard-codes
   21 until a solidity-step release exports it; machine/step v0.15.0 exports
   none, and the only Solidity test echoes the literal. A new node refuses a
   mismatched deployment, but an old node binary against a deployment whose
   step changed and whose literal did not would start silently (a lead).
   Importing the upstream constant changes the bytecode and the addresses,
   so it rides the next deployment bundle (normally the next generation);
   list it as a known item.
6. The leaf-proof gas witnesses in CI: done. `Gas.WIN_LEAF_MATCH =
   5,543,000` (`prt/contracts/src/tournament/libs/Gas.sol:35`), the largest
   allocation, is witnessed only by the 12 full-stack FFI tests in
   `cartesi-rollups/contracts/test/gas/PrtLeafProofGasFfi.t.sol` (the
   maximum input measured 5,040,748), which `rollups-contracts::test`
   excludes. The calldata refund calibration (cartesi/dave#287) accepted
   them by a manual run; the `prt-contracts` CI job now runs
   `just test-prt-gas`, so a change that pushes a leaf proof past its
   allocation fails CI.

The refill review's release-evidence item ("Remaining assurance work", 3) is
covered elsewhere: the gas calibration by the calldata refund calibration
(reviews/2026-10-02-prt-calldata-refund-calibration), active real-machine
tall-leaf differentials by the leaf builder's active-big-cycle differential
(cartesi/dave#287), dense height-37 performance by
measurements/node-vs-emulator.md with the v0.21 confirmation in todo.md; full
E2E is the per-PR smoke, since dense disputes left e2e by design when the
suite was cut to the black-box smoke (cartesi/dave#287).

## Freeze and audit identity

Every address is CREATE2 over initcode that includes Forge's metadata hash,
so any byte change in a deployed contract's sources, a comment included,
moves its address and every address built from it (build-system.md,
"Deployment generations"). The audited commit must therefore be identifiable
against the released one:

- `just prt-contracts::compatibility-hashes` (`prt/contracts/justfile:69-95`)
  fingerprints only `Tournament` and `MultiLevelTournamentFactory`: wire
  ABI, storage layout, and creation and runtime bytecode with and without
  metadata. Extend it to `CanonicalTournamentParametersProvider` (the
  canonical switch changes it), `CartesiStateTransition` (the `CM_MARCHID`
  import and upstream PR #390 change it), `DaveConsensus` and
  `DaveAppFactory`.
- Record its output and a clean `just measure-prt-gas` at the audit commit
  and again at the release commit. Equal metadata-free fingerprints show
  that a later change was source-only.
- After the freeze, `src/` takes only audit fixes, each through the
  contract-change gate and recalibrated if it moves gas. Keep comment-only
  edits out; if one is unavoidable, show the metadata-free fingerprints are
  equal.

Terms: a wire break (the Tournament ABI or the clone arguments) starts a new
generation; any other bytecode change makes a new deployment bundle with new
addresses (build-system.md).

## Ordering

1. This PR (cartesi/dave#287): the node debts and R10, and the docs. Its
   calldata refund change set the allocations, and their calibration was
   accepted under release Forge; the contracts' later code changes, the
   child-return clamp on the `winInnerTournament` path and the narrowing of
   the calldata meter to the leaf proof, stay within them (the gas witnesses
   pass). The deployment script registers the
   Arbitrum entries at the parent chain's 12 s, so their addresses now equal
   Ethereum's and Sepolia's.
2. A release candidate for the staging pipeline and testnet. It is a new
   generation: this PR's child-return refill changed the
   `TournamentParameters` row and the clone arguments, so this node cannot
   start against earlier contracts, and this PR's node fixes (the
   terminal-application hold, seam 2, input-index continuity) reach
   integrators only with it. The candidate is their main path, not an extra.
3. R19, in its own PR.
4. The canonical two-level switch, in its own PR. It changes only the
   provider: the `Tournament` and factory fingerprints hold, the provider's
   initcode and the addresses built from it move, and the bonds it implies
   are already pinned (`prt/contracts/test/accounting/RefundReserve.t.sol:114-115`).
   What remains to review is the allowance (one refill level fewer) and the
   provider's bytecode, which the hashes do not yet cover. It moves no gas.
5. The remaining pre-audit items.
6. Freeze: record the identity above, and tag a pre-release so integrators
   can bump against the frozen ABI while the audit runs.
7. The audit, on that exact commit.
8. Audit fixes only, as above.
9. Tag the audited release, naming the generation, addresses, geometry and
   bonds in the release notes.

The tournament events ABI stays as is in this PR. A later field addition is
a wire break: it lands before the freeze or waits for the next generation
(upstream PR #390 already forces one).

## Open questions

- Scope: `prt/contracts` only, or also `DaveConsensus` and `DaveAppFactory`,
  the deployment scripts, and `machine/step` with `CartesiStateTransition`.
- The firm and the date.
- Whether R19 gates the audit's start or is handed to the auditors with the
  scope.
- Whether the canonical switch lands before the freeze; if its measurement
  slips, audit three levels and review the switch afterwards as a
  provider-only delta, or wait.
- Whether the deployer's table is formally inside the trust boundary.
