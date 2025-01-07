// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use std::{env, path::PathBuf, process::Command};

mod feature_checks {
    #[cfg(all(feature = "build_uarch", feature = "copy_uarch",))]
    compile_error!("Features `build_uarch` and `copy_uarch` are mutually exclusive");

    #[cfg(all(feature = "build_uarch", feature = "download_uarch"))]
    compile_error!("Features `build_uarch` and `download_uarch` are mutually exclusive");

    #[cfg(all(feature = "copy_uarch", feature = "download_uarch"))]
    compile_error!("Features `copy_uarch`, and `download_uarch` are mutually exclusive");

    #[cfg(not(any(
        feature = "copy_uarch",
        feature = "download_uarch",
        feature = "build_uarch",
        feature = "external_cartesi",
    )))]
    compile_error!("At least one of `build_uarch`, `copy_uarch`, `download_uarch`, and `external_cartesi` must be set");
}

fn main() {
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Directory where `libcartesi.a` is located after it's built.
    let machine_dir_path = PathBuf::from("../../emulator")
        // Canonicalize the path as `rustc-link-search` requires an absolute
        // path.
        .canonicalize()
        .expect("cannot canonicalize path");

    // Clean build artifacts and start from scratch
    // clean(&machine_dir_path);

    // tell Cargo where to look for libraries
    cfg_if::cfg_if! {
        if #[cfg(feature = "external_cartesi")] {
            let libpath =
                env::var("LIBCARTESI_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|_| machine_dir_path.join("src"));
            println!("cargo:rustc-link-search={}", libpath.to_str().unwrap());
        } else {
            build_cm::build(&machine_dir_path, &out_path);
            println!("cargo:rustc-link-search={}", out_path.to_str().unwrap());
        }
    }

    // static link
    cfg_if::cfg_if! {
        if #[cfg(feature = "remote_machine")] {
            println!("cargo:rustc-link-lib=static=cartesi_jsonrpc");
        } else {
            println!("cargo:rustc-link-lib=static=cartesi");
        }
    }

    //
    //  Generate bindings
    //

    #[allow(clippy::needless_late_init)]
    let include_path;
    cfg_if::cfg_if! {
        if #[cfg(feature = "external_cartesi")] {
            include_path = env::var("INCLUDECARTESI_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|_| machine_dir_path.join("src"));

        } else {
            include_path = machine_dir_path.join("src");
        }
    };

    // machine api
    let machine_bindings = bindgen::Builder::default()
        .header(include_path.join("machine-c-api.h").to_str().unwrap())
        .generate()
        .expect("Unable to generate machine bindings");

    // htif constants
    let htif = bindgen::Builder::default()
        .header(include_path.join("htif-defines.h").to_str().unwrap())
        .generate()
        .expect("Unable to generate htif bindings");

    // pma constants
    let pma = bindgen::Builder::default()
        .header(include_path.join("pma-defines.h").to_str().unwrap())
        .generate()
        .expect("Unable to generate pma bindings");

    // Write the bindings to the `$OUT_DIR/bindings.rs` and `$OUT_DIR/htif.rs` files.
    machine_bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write machine bindings");
    htif.write_to_file(out_path.join("htif.rs"))
        .expect("Couldn't write htif defines");
    pma.write_to_file(out_path.join("pma.rs"))
        .expect("Couldn't write pma defines");

    // Setup reruns
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rerun-if-changed={}",
        machine_dir_path.join(".git").display()
    );
    println!("cargo::rerun-if-env-changed=UARCH_PRISTINE_HASH_PATH");
    println!("cargo::rerun-if-env-changed=UARCH_PRISTINE_RAM_PATH");
}

#[cfg(not(feature = "external_cartesi"))]
mod build_cm {
    use std::{fs, path::Path, process::Command};

    pub fn build(machine_dir_path: &Path, out_path: &Path) {
        // Get uarch
        cfg_if::cfg_if! {
            if #[cfg(feature = "build_uarch")] {
                ()
            } else if #[cfg(feature = "copy_uarch")] {
                let uarch_path = machine_dir_path.join("uarch");
                copy_uarch::copy(&uarch_path)
            } else if #[cfg(feature = "download_uarch")] {
                download_uarch::download(machine_dir_path);
            } else {
                panic!("Internal error, no way specified to get uarch");
            }
        }

        // Build and link emulator

        // build dependencies
        Command::new("make")
            .args(["submodules"])
            .current_dir(machine_dir_path)
            .status()
            .expect("Failed to run setup `make submodules`");
        Command::new("make")
            .args(["bundle-boost"])
            .current_dir(machine_dir_path)
            .status()
            .expect("Failed to run `make bundle-boost`");

        // build `libcartesi.a` and `libcartesi_jsonrpc.a`, release, no `libslirp`
        Command::new("make")
            .args([
                "-C",
                "src",
                "release=yes",
                "slirp=no",
                "libcartesi.a",
                "libcartesi_jsonrpc.a",
            ])
            .current_dir(machine_dir_path)
            .status()
            .expect("Failed to build `libcartesi.a` and/or `libcartesi_jsonrpc.a`");

        // copy `libcartesi.a` to OUT_DIR
        let libcartesi_path = machine_dir_path.join("src").join("libcartesi.a");
        let libcartesi_new_path = out_path.join("libcartesi.a");
        fs::copy(&libcartesi_path, &libcartesi_new_path).unwrap_or_else(|_| {
            panic!(
                "Failed to copy `libcartesi.a` {:?} to OUT_DIR {:?}",
                libcartesi_path, libcartesi_new_path
            )
        });

        // copy `libcartesi_jsonrpc.a` to OUT_DIR
        let libcartesi_jsonrpc_path = machine_dir_path.join("src").join("libcartesi_jsonrpc.a");
        let libcartesi_jsonrpc_new_path = out_path.join("libcartesi_jsonrpc.a");
        fs::copy(libcartesi_jsonrpc_path, libcartesi_jsonrpc_new_path)
            .expect("Failed to move `libcartesi_jsonrpc.a` to OUT_DIR");
    }

    #[cfg(feature = "copy_uarch")]
    mod copy_uarch {
        use std::{env, fs, path::Path};

        fn copy(uarch_path: &Path) {
            let uarch_pristine_hash_path =
                env::var("UARCH_PRISTINE_HASH_PATH").expect("`UARCH_PRISTINE_HASH_PATH` not set");
            let uarch_pristine_ram_path =
                env::var("UARCH_PRISTINE_RAM_PATH").expect("`UARCH_PRISTINE_RAM_PATH` not set");

            fs::copy(
                uarch_pristine_hash_path,
                uarch_path.join("uarch-pristine-hash.c").to_str().unwrap(),
            )
            .expect("Failed to move `uarch-pristine-hash.c` to `uarch/`");

            fs::copy(
                uarch_pristine_ram_path,
                uarch_path.join("uarch-pristine-ram.c").to_str().unwrap(),
            )
            .expect("Failed to move `uarch-pristine-ram.c` to `uarch/`");
        }
    }

    #[cfg(feature = "download_uarch")]
    mod download_uarch {
        use bytes::Bytes;
        use std::{
            fs::{self, OpenOptions},
            io::{self, Read, Write},
            path::Path,
            process::{Command, Stdio},
        };

        pub fn download(machine_dir_path: &Path) {
            // apply git patche for 0.18.1
            let patch_file = machine_dir_path.join("add-generated-files.diff");

            download_git_patch(&patch_file, "v0.18.1");
            apply_git_patch(&patch_file, machine_dir_path);
        }

        fn download_git_patch(patch_file: &Path, target_tag: &str) {
            let emulator_git_url = "https://github.com/cartesi/machine-emulator";

            let patch_url = format!(
                "{}/releases/download/{}/add-generated-files.diff",
                emulator_git_url, target_tag,
            );

            // get
            let diff_data = reqwest::blocking::get(patch_url)
                .expect("error downloading diff of generated files")
                .bytes()
                .expect("error getting diff request body");

            // write to file
            write_bytes_to_file(patch_file.to_str().unwrap(), diff_data)
                .expect("failed to write `add-generated-files.diff`");
        }

        fn apply_git_patch(patch_file: &Path, target_dir: &Path) {
            // Open the patch file
            let mut patch = fs::File::open(patch_file).expect("fail to open patch file");

            // Create a command to run `patch -Np0`
            let mut cmd = Command::new("patch")
                .arg("-Np0")
                .stdin(Stdio::piped())
                .current_dir(target_dir)
                .spawn()
                .expect("fail to spawn patch command");

            // Write the contents of the patch file to the command's stdin
            if let Some(ref mut stdin) = cmd.stdin {
                let mut buffer = Vec::new();
                patch
                    .read_to_end(&mut buffer)
                    .expect("fail to read patch content");
                stdin
                    .write_all(&buffer)
                    .expect("fail to write patch to pipe");
            }

            // Wait for the command to complete
            let status = cmd.wait().expect("fail to wait for patch command");

            if !status.success() {
                eprintln!("Patch command failed with status: {:?}", status);
            }
        }

        fn write_bytes_to_file(path: &str, data: Bytes) -> io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(path)
                .unwrap_or_else(|_| panic!("failed to open file {}", path));

            file.write_all(&data)?;
            file.flush() // Ensure all data is written to disk
        }
    }
}

#[allow(dead_code)]
fn clean(path: &PathBuf) {
    // clean build artifacts
    Command::new("make")
        .args(["clean", "depclean ", "distclean"])
        .current_dir(path)
        .status()
        .expect("Failed to run setup `make clean depclean distclean`");

    Command::new("rm")
        .args(["src/*o.tmp"])
        .current_dir(path)
        .status()
        .expect("Failed to delete src/*.o.tmp files");
}
