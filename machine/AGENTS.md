# Machine - agent guidance

This directory pins the Cartesi Machine: the `emulator/` and `step/` git
submodules and the Rust bindings that link against the emulator. It is a
cross-implementation seam, and work that starts here can silently break
agreement between the on-chain and off-chain state transitions - the rule
lives in `prt/contracts/AGENTS.md` but an agent starting in this directory
would never load it, hence this file.

- `emulator/` and `step/` are upstream submodules. Nothing under them is
  hand-edited in this repo; changes happen upstream and land here as pin
  bumps. The emulator additionally needs generated sources and Boost headers
  owned by the `machine` Just module. Use `just machine::setup` for the pinned
  release or `just machine::generate-sources` for a clean intermediary commit;
  do not hand-edit or copy generated files into the submodule.
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
- Release acquisition and image-generation pins are spread across
  `machine/script/cartesi-machine-source.sh`, CI, `test/programs/`'s justfile,
  and the nix devshell flake outside this repo. Semantic version guards also
  exist in the Rust wrapper and node tests. Drift between them is a standing
  hazard (`docs/build-system.md`); search for the current version during a bump
  and rebuild the machine images under `test/programs/`.
- Any set `LIBCARTESI_PATH` selects an external static library, and the path
  must be absolute. When it is unset, Cargo incrementally builds an explicitly
  prepared source checkout. `build.rs` owns no downloads. The exact provider
  and preparation contract is documented in `machine/README.md`.
