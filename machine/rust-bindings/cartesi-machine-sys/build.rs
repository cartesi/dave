// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)
use sha2::{Digest, Sha256};
use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
};

const C_API_HEADER: &str = "cm.h";
const C_API_VERSION_HEADER: &str = "cm-version.h";
const SOURCE_PREPARATION_STATE: &str = "../../../target/machine-source/prepared-generated-sources";
const GENERATED_SOURCE_INPUTS: [&str; 4] = [
    "src/cm-version.h",
    "src/interpret-jump-table.hpp",
    "uarch/uarch-pristine-hash.c",
    "uarch/uarch-pristine-ram.c",
];
const PREPARED_SOURCE_INPUTS: [&str; 6] = [
    "uarch/uarch-pristine-hash.c",
    "uarch/uarch-pristine-ram.c",
    "src/cm-version.h",
    "src/interpret-jump-table.hpp",
    "third-party/downloads/boost/version.hpp",
    "third-party/downloads/boost/.dave-archive-sha256",
];

fn main() {
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    let external_lib_dir = env::var_os("LIBCARTESI_PATH").map(PathBuf::from);
    #[cfg(feature = "external_cartesi")]
    assert!(
        external_lib_dir.is_some(),
        "the `external_cartesi` feature requires `LIBCARTESI_PATH` to point to a directory containing libcartesi.a"
    );

    let include_path = if let Some(lib_dir) = external_lib_dir.as_ref() {
        assert!(
            lib_dir.is_absolute(),
            "LIBCARTESI_PATH must be an absolute directory, found `{}`",
            lib_dir.display()
        );
        link_external(lib_dir, &out_path);
        external_include_path(lib_dir)
    } else {
        let machine_dir = source_checkout();
        build_cm::build(&machine_dir, &out_path);
        println!("cargo:rustc-link-search={}", out_path.display());
        for input in PREPARED_SOURCE_INPUTS {
            println!(
                "cargo:rerun-if-changed={}",
                machine_dir.join(input).display()
            );
        }
        for path in submodule_git_watch_paths(&machine_dir) {
            println!("cargo:rerun-if-changed={}", path.display());
        }
        machine_dir.join("src")
    };

    // Static link. Source fallback is built with `slirp=no`. External
    // providers may be the upstream release package, whose archive references
    // libslirp; `link_external` adds that provider dependency.
    if cfg!(feature = "remote_machine") {
        println!("cargo:rustc-link-lib=static=cartesi_jsonrpc");
    } else {
        println!("cargo:rustc-link-lib=static=cartesi");
    }

    // OpenMP linker configuration (cross-platform)
    if cfg!(target_os = "macos") {
        // macOS: Try Homebrew first, then MacPorts
        let homebrew_libomp = PathBuf::from("/opt/homebrew/opt/libomp");
        if homebrew_libomp.exists() {
            println!("cargo:rustc-link-search={}/lib", homebrew_libomp.display());
            println!("cargo:rustc-link-lib=omp");
        } else {
            let macports_libomp = PathBuf::from("/opt/local/lib/libomp");
            if macports_libomp.exists() {
                println!("cargo:rustc-link-search=/opt/local/lib/libomp");
                println!("cargo:rustc-link-lib=gomp");
            } else {
                // Fallback: let system linker find it
                println!("cargo:rustc-link-lib=omp");
            }
        }
    } else {
        // Linux and other Unix-like systems: libgomp comes with GCC
        println!("cargo:rustc-link-lib=gomp");
    }

    let api_header = include_path.join(C_API_HEADER);
    let api_version_header = include_path.join(C_API_VERSION_HEADER);
    assert!(
        api_header.is_file(),
        "Cartesi Machine C API header not found at `{}`; set `INCLUDECARTESI_PATH` to the directory containing `{C_API_HEADER}`",
        api_header.display()
    );
    assert!(
        api_version_header.is_file(),
        "Cartesi Machine version header not found at `{}`; `{C_API_HEADER}` includes `{C_API_VERSION_HEADER}`",
        api_version_header.display()
    );
    println!("cargo:rerun-if-changed={}", api_header.display());
    println!("cargo:rerun-if-changed={}", api_version_header.display());

    let machine_bindings = bindgen::Builder::default()
        .header(api_header.to_str().unwrap())
        .allowlist_item("^cm_.*")
        .allowlist_item("^CM_.*")
        .merge_extern_blocks(true)
        .prepend_enum_name(false)
        .translate_enum_integer_types(true)
        .generate()
        .expect("Unable to generate machine bindings");

    machine_bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write machine bindings");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo::rerun-if-env-changed=LIBCARTESI_PATH");
    println!("cargo::rerun-if-env-changed=INCLUDECARTESI_PATH");
}

fn source_checkout() -> PathBuf {
    let checkout = PathBuf::from("../../emulator");
    let checkout = checkout.canonicalize().unwrap_or_else(|e| {
        panic!(
            "Cartesi Machine source checkout is unavailable at `{}`: {e}\nRun `just machine::setup` before building without `LIBCARTESI_PATH`.",
            checkout.display()
        )
    });

    let missing: Vec<_> = PREPARED_SOURCE_INPUTS
        .iter()
        .map(|path| checkout.join(path))
        .filter(|path| !path.exists())
        .collect();
    if !missing.is_empty() {
        let missing = missing
            .iter()
            .map(|path| format!("  - {}", path.display()))
            .collect::<Vec<_>>()
            .join("\n");
        panic!(
            "Cartesi Machine source checkout is not prepared; missing inputs:\n{missing}\nRun `just machine::setup` before building without `LIBCARTESI_PATH`."
        );
    }

    validate_source_preparation(&checkout);
    checkout
}

fn validate_source_preparation(checkout: &Path) {
    let state =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join(SOURCE_PREPARATION_STATE);
    let contents = std::fs::read_to_string(&state).unwrap_or_else(|e| {
        panic!(
            "Cartesi Machine generated-source preparation state is unavailable at `{}`: {e}\nRun `just machine::setup` for the pinned release, or prepare the selected emulator commit explicitly.",
            state.display()
        )
    });
    println!("cargo:rerun-if-changed={}", state.display());

    let lines: Vec<_> = contents.lines().collect();
    assert_eq!(
        lines.len(),
        7,
        "invalid Cartesi Machine generated-source preparation state at `{}`",
        state.display()
    );
    assert_eq!(lines[0], "format 1", "unsupported preparation-state format");
    let provider = lines[1]
        .strip_prefix("provider ")
        .expect("invalid generated-source provider field");
    assert!(
        provider == "generated" || provider.starts_with("release:v"),
        "invalid generated-source provider in `{}`",
        state.display()
    );

    let output = Command::new("git")
        .arg("-C")
        .arg(checkout)
        .args(["rev-parse", "--verify", "HEAD^{commit}"])
        .output()
        .unwrap_or_else(|e| panic!("failed to inspect Cartesi Machine HEAD: {e}"));
    assert!(
        output.status.success(),
        "failed to inspect Cartesi Machine HEAD: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let head = String::from_utf8(output.stdout).expect("Cartesi Machine HEAD is not UTF-8");
    assert_eq!(
        lines[2],
        format!("emulator-head {}", head.trim()),
        "prepared generated sources do not belong to the checked-out Cartesi Machine commit; run `just machine::prepare-release` for the pinned release or `just machine::generate-sources` for an intermediary commit"
    );

    for (line, input) in lines[3..].iter().zip(GENERATED_SOURCE_INPUTS) {
        let path = checkout.join(input);
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|e| panic!("failed to read prepared source `{}`: {e}", path.display()));
        let actual = format!("{:x}", Sha256::digest(bytes));
        assert_eq!(
            *line,
            format!("generated {actual} {input}"),
            "prepared source `{}` does not match its preparation state; rerun the source-preparation command",
            path.display()
        );
    }
}

fn external_include_path(lib_dir: &Path) -> PathBuf {
    env::var_os("INCLUDECARTESI_PATH")
        .map(PathBuf::from)
        .inspect(|path| {
            assert!(
                path.is_absolute(),
                "INCLUDECARTESI_PATH must be an absolute directory, found `{}`",
                path.display()
            );
        })
        .unwrap_or_else(|| {
            lib_dir
                .parent()
                .unwrap_or_else(|| {
                    panic!(
                        "cannot infer the Cartesi Machine include directory from `{}`; set `INCLUDECARTESI_PATH`",
                        lib_dir.display()
                    )
                })
                .join("include/cartesi-machine")
        })
}

/// Returns the Git paths that change when the source checkout moves.
///
/// The gitfile selects the submodule repository, while its index tracks the
/// checked-out tree across detached and attached checkouts. Every emitted path
/// exists, so Cargo does not perpetually rerun the build script waiting for one.
fn submodule_git_watch_paths(checkout: &Path) -> Vec<PathBuf> {
    let dot_git = checkout.join(".git");
    let mut paths = Vec::with_capacity(2);
    let git_dir = if dot_git.is_dir() {
        dot_git.clone()
    } else {
        let gitfile = std::fs::read_to_string(&dot_git).unwrap_or_else(|e| {
            panic!(
                "failed to read Cartesi Machine gitfile `{}`: {e}; run `just machine::prepare-release`",
                dot_git.display()
            )
        });
        let path = PathBuf::from(
            gitfile
                .strip_prefix("gitdir: ")
                .map(str::trim)
                .unwrap_or_else(|| panic!("invalid gitfile `{}`", dot_git.display())),
        );
        paths.push(dot_git);
        if path.is_absolute() {
            path
        } else {
            checkout.join(path)
        }
    };

    let index = git_dir.join("index");
    let index = index.canonicalize().unwrap_or_else(|e| {
        panic!(
            "Cartesi Machine Git index not found at `{}`: {e}; run `just machine::prepare-release`",
            index.display()
        )
    });
    paths.push(index);
    paths
}

// Stage the external static archives into OUT_DIR and search only there.
// Searching the provider's lib dir directly is not safe: it usually also
// contains libcartesi dylibs, and ld64 prefers a dylib over an archive
// even under rustc's `static=` modifier, producing binaries that need an
// rpath into the provider's tree at runtime.
fn link_external(libdir: &Path, out_path: &Path) {
    let cartesi = libdir.join("libcartesi.a");
    println!("cargo:rerun-if-changed={}", cartesi.display());
    stage_archive(&cartesi, out_path);

    if cfg!(feature = "remote_machine") {
        let jsonrpc = libdir.join("libcartesi_jsonrpc.a");
        println!("cargo:rerun-if-changed={}", jsonrpc.display());
        stage_archive(&jsonrpc, out_path);
    }

    println!("cargo:rustc-link-search={}", out_path.display());
    println!("cargo:rustc-link-lib=slirp");
}

fn stage_archive(archive: &Path, out_path: &Path) {
    let staged = out_path.join(archive.file_name().unwrap());
    // fs::copy preserves the source mode; a nix-store source stages a
    // read-only copy that the next build-script run cannot overwrite.
    if staged.exists() {
        std::fs::remove_file(&staged)
            .unwrap_or_else(|e| panic!("failed to unstage `{}`: {e}", staged.display()));
    }
    std::fs::copy(archive, &staged)
        .unwrap_or_else(|e| panic!("failed to copy `{}` to OUT_DIR: {e}", archive.display()));
}

mod build_cm {
    use std::{path::Path, process::Command};

    pub fn build(machine_dir: &Path, out_path: &Path) {
        let libcartesi = machine_dir.join("src/libcartesi.a");
        let libcartesi_jsonrpc = machine_dir.join("src/libcartesi_jsonrpc.a");

        // Preparation owns all downloads and generated sources. Make is
        // incremental, so a changed Git index checks the selected targets,
        // while an unchanged Cargo invocation does not run this script.
        run_make(
            machine_dir,
            &[
                "-C",
                "src",
                "release=yes",
                "slirp=no",
                "libcartesi.a",
                "libcartesi_jsonrpc.a",
            ],
        );

        // Reuse the same staging path as external archives. In particular,
        // this removes a read-only Nix-store copy left by a previous provider.
        super::stage_archive(&libcartesi, out_path);
        super::stage_archive(&libcartesi_jsonrpc, out_path);
    }

    fn run_make(machine_dir: &Path, args: &[&str]) {
        let status = Command::new("make")
            .args(args)
            .current_dir(machine_dir)
            .status()
            .unwrap_or_else(|e| panic!("failed to run `make {}`: {e}", args.join(" ")));
        assert!(
            status.success(),
            "`make {}` failed with {status}",
            args.join(" ")
        );
    }
}
