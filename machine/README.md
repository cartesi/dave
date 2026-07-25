# Machine integration

Everything that connects Dave to the Cartesi Machine.

- `emulator/` (git submodule): the machine emulator (C++). Some of its
  sources are generated; `just apply-generated-files-diff` downloads them
  from the matching emulator release (sha256-pinned) instead of requiring
  the generation toolchain. Built by `make`, or transparently by
  `cartesi-machine-sys`'s build script.
- `step/` (git submodule): the auto-generated Solidity implementation of
  the uarch state transition (machine-solidity-step), consumed by
  `prt/contracts`. Its `EmulatorConstants.sol` must stay in sync with the
  emulator version; there is a guard test in
  `cartesi-rollups/node/src/engine/constants.rs`.
- `rust-bindings/cartesi-machine-sys`: raw FFI bindings. Its `build.rs`
  links `libcartesi` with this precedence: the `external_cartesi`
  feature, else a `LIBCARTESI_PATH` in the environment (the nix devshell
  exports one), else it builds the submodule from source. The fallback
  is also how to test an unreleased emulator commit: unset
  `LIBCARTESI_PATH` and cargo builds the submodule checkout. The
  `download_uarch` feature fetches the pinned uarch binary for the
  from-source path.
- `rust-bindings/cartesi-machine`: the safe Rust API used by the node.

When bumping the emulator version, bump `emulator/` and `step/` together
and update the version pins listed in `docs/build-system.md`; the
constants guard test is designed to fail loudly if they drift.
