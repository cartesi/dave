# Machine integration

Everything that connects Dave to the Cartesi Machine.

- `emulator/` is the C++ machine-emulator submodule. Its release source tree
  omits four generated files; the machine-local preparation lifecycle owns
  acquiring or generating them and the Boost headers used by the native build.
- `step/` is the generated Solidity implementation of the uarch state
  transition. Its `EmulatorConstants.sol` must stay in sync with the emulator;
  `cartesi-rollups/node/src/engine/constants.rs` guards that agreement.
- `rust-bindings/cartesi-machine-sys` provides the raw C API bindings and links
  the selected `libcartesi.a`.
- `rust-bindings/cartesi-machine` is the safe Rust API used by the node.

## Library provider

Provider selection has one switch:

- Any set `LIBCARTESI_PATH` selects an external provider. It must name an
  absolute directory containing `libcartesi.a`; an empty or invalid value is
  an error and never falls back to the submodule. `INCLUDECARTESI_PATH` may
  explicitly name the absolute directory containing `cm.h`. When it is unset,
  the build infers the conventional sibling `include/cartesi-machine`
  directory.
- When `LIBCARTESI_PATH` is unset, Cargo uses the prepared `emulator/` checkout
  as the source provider and runs incremental Make with `slirp=no`.

The Nix devshell is an external provider and exports the library path from its
immutable Cartesi Machine package. With a valid external provider, raw Cargo
commands do not initialize or build the emulator submodule. The sys crate's
build script is network-free in both modes: it selects the provider, generates
Rust bindings, stages static archives, and links them; it never downloads or
generates source inputs.

## Source-provider lifecycle

The `machine` Just module owns source preparation and build:

- `just machine::setup` prepares the pinned v0.21 release, verifies and
  publishes its generated files and Boost headers, then performs one native
  incremental build. It only validates and skips this work when an external
  provider is selected.
- `just machine::prepare-release` prepares only the four generated files from
  the pinned release artifact. It refuses an emulator revision other than the
  exact release commit.
- `just machine::prepare-boost` prepares the pinned, verified Boost headers.
- `just machine::generate-sources` runs the upstream generator for the current
  clean emulator commit. It uses the upstream Docker toolchain unless
  `DEV_ENV_HAS_TOOLCHAIN=yes` declares a compatible native toolchain. Follow it
  with `prepare-boost` and `build` when testing an intermediary commit.
- `just machine::build` validates the selected provider and incrementally
  builds an already prepared source checkout when needed.
- `just machine::check` validates the selected external provider or prepared
  source inputs without changing the checkout.
- `just machine::clean` removes source-provider outputs while retaining the
  verified download cache.

Cargo watches the selected external archive and header. In source mode it also
watches the prepared inputs plus the submodule gitfile and resolved Git index,
so moving the submodule checkout rechecks Make while an unchanged second Cargo
invocation does not.

When bumping the emulator, update `emulator/` and `step/` together, update the
release pins listed in [the build-system documentation](../docs/build-system.md),
rebuild the program images, and run the cross-implementation state-transition
and computation-hash gates.
