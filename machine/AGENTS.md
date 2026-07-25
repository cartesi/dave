# Machine - agent guidance

This directory pins the Cartesi Machine: the `emulator/` and `step/` git
submodules and the Rust bindings that link against the emulator. It is a
cross-implementation seam, and work that starts here can silently break
agreement between the on-chain and off-chain state transitions - the rule
lives in `prt/contracts/AGENTS.md` but an agent starting in this directory
would never load it, hence this file.

- `emulator/` and `step/` are upstream submodules. Nothing under them is
  hand-edited in this repo; changes happen upstream and land here as pin
  bumps. The emulator additionally needs generated sources fetched by
  `just apply-generated-files-diff` (sha256-pinned; see the root justfile).
- A pin bump is not a version bump. Instruction semantics are owned by
  `machine/step`, and the Solidity adapters
  (`prt/contracts/src/state-transition/`), the emulator, and both
  off-chain clients must agree across that seam. Read
  `prt/contracts/AGENTS.md` (the seam rule and its non-claims) and
  `docs/computation-hash.md` before bumping either submodule, and keep
  cross-implementation proof vectors passing
  (`just prt-contracts::test-stf`).
- `step/src/EmulatorConstants.sol` must stay in sync with the emulator
  version; the guard test is
  `cartesi-rollups/node/src/engine/constants.rs`.
- Version pins are spread across the root justfile
  (`apply-generated-files-diff`), CI (`.github/workflows/build.yml`, the
  cartesi-machine action), `test/programs/`'s justfile, and the nix
  devshell flake (outside this repo). Drift between them is a standing
  hazard (docs/build-system.md); a bump must visit all of them, and the
  machine images under `test/programs/` must be rebuilt.
- `rust-bindings/cartesi-machine-sys` linking precedence
  (`external_cartesi` feature, `LIBCARTESI_PATH`, submodule build) is
  documented in `machine/README.md`.
