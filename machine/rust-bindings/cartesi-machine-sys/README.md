# cartesi-machine-sys

This crate offers native bindings for the [cartesi emulator](https://github.com/cartesi/machine-emulator), enabling local manipulation of a Cartesi machine.

When `LIBCARTESI_PATH` is set, it must be absolute and the build links the
prebuilt static archive in that directory. `INCLUDECARTESI_PATH` can select its
headers with an absolute path; otherwise the conventional sibling
`include/cartesi-machine` directory is used. The `external_cartesi` feature
remains as manifest-level enforcement for packaged consumers: it requires
`LIBCARTESI_PATH` instead of allowing the source fallback.

When `LIBCARTESI_PATH` is unset, the build incrementally builds the prepared
`machine/emulator` checkout with `slirp=no`. This build script never downloads
or generates source inputs. Run `just machine::setup` for the pinned release.
When testing an intermediary emulator commit, run
`just machine::generate-sources`, `just machine::prepare-boost`, and
`just machine::build` explicitly.
