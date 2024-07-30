use std::{env, fs, path::PathBuf, process::Command};

use hex_literal::hex;
use sha1::{Digest, Sha1};

#[cfg(all(feature = "build_uarch", feature = "copy_uarch",))]
compile_error!("Features `build_uarch` and `copy_uarch` are mutually exclusive");

#[cfg(all(feature = "build_uarch", feature = "download_uarch"))]
compile_error!("Features `build_uarch` and `download_uarch` are mutually exclusive");

#[cfg(all(feature = "copy_uarch", feature = "download_uarch"))]
compile_error!("Features `copy_uarch`, and `download_uarch` are mutually exclusive");

#[cfg(not(any(feature = "copy_uarch", feature = "download_uarch")))]
compile_error!("At least one of `build_uarch`, `copy_uarch`, and `download_uarch` must be set");

const UARCH_PRISTINE_HASH_URL: &str =
    "https://github.com/cartesi/machine-emulator/releases/download/v0.17.0/uarch-pristine-hash.c";
const UARCH_PRISTINE_HASH_CHECKSUM: [u8; 20] = hex!("b20b3b025166c0f3959ee29df3c7b849757f2c5f");

const UARCH_PRISTINE_RAM_URL: &str =
    "https://github.com/cartesi/machine-emulator/releases/download/v0.17.0/uarch-pristine-ram.c";
const UARCH_PRISTINE_RAM_CHECKSUM: [u8; 20] = hex!("da3d6390aa4ea098311f11e91ff7f1002f874303");

use bytes::Bytes;
use std::fs::OpenOptions;
use std::io::{self, Write};

fn main() {
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Directory where `libcartesi.a` is located after it's built.
    let machine_dir_path = PathBuf::from("../../emulator")
        // Canonicalize the path as `rustc-link-search` requires an absolute
        // path.
        .canonicalize()
        .expect("cannot canonicalize path");
    let libdir_path = machine_dir_path.join("src");
    let uarch_path = machine_dir_path.join("uarch");

    // clean build artifacts and start from scratch
    clean(&machine_dir_path);

    //
    // Get uarch
    //

    cfg_if::cfg_if! {
        if #[cfg(feature = "build_uarch")] {
            ()
        } else if #[cfg(feature = "copy_uarch")] {
            copy_uarch(&uarch_path)
        } else if #[cfg(feature = "download_uarch")] {
            download_uarch(&uarch_path);
        } else {
            panic!("Internal error, no way specified to get uarch");
        }
    }

    //
    // Build and link emulator
    //

    // build dependencies
    Command::new("make")
        .args(&["submodules", "downloads", "dep"])
        .current_dir(&machine_dir_path)
        .status()
        .expect("Failed to run setup `make submodules downloads dep`");
    Command::new("make")
        .args(&["bundle-boost"])
        .current_dir(&machine_dir_path)
        .status()
        .expect("Failed to run `make bundle-boost`");

    // build `libcartesi.a`, release, no `libslirp`
    Command::new("make")
        .args(&[
            "-C",
            "src",
            "release=yes",
            "slirp=no",
            "libcartesi.a",
            "libcartesi_jsonrpc.a",
        ])
        .current_dir(&machine_dir_path)
        .status()
        .expect("Failed to build `libcartesi.a` and/or `libcartesi_jsonrpc.a`");

    // copy `libcartesi.a` to OUT_DIR
    let libcartesi_path = libdir_path.join("libcartesi.a");
    let libcartesi_new_path = out_path.join("libcartesi.a");
    fs::copy(&libcartesi_path, &libcartesi_new_path).expect(&format!(
        "Failed to copy `libcartesi.a` {:?} to OUT_DIR {:?}",
        libcartesi_path, libcartesi_new_path
    ));

    // copy `libcartesi_jsonrpc.a` to OUT_DIR
    let libcartesi_jsonrpc_path = libdir_path.join("libcartesi_jsonrpc.a");
    let libcartesi_jsonrpc_new_path = out_path.join("libcartesi_jsonrpc.a");
    fs::copy(libcartesi_jsonrpc_path, libcartesi_jsonrpc_new_path)
        .expect("Failed to move `libcartesi_jsonrpc.a` to OUT_DIR");

    // tell Cargo where to look for libraries
    println!("cargo:rustc-link-search={}", out_path.to_str().unwrap());

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

    // machine api
    let machine_bindings = bindgen::Builder::default()
        .header(libdir_path.join("machine-c-api.h").to_str().unwrap())
        .generate()
        .expect("Unable to generate machine bindings");

    // htif constants
    let htif = bindgen::Builder::default()
        .header(libdir_path.join("htif-defines.h").to_str().unwrap())
        .generate()
        .expect("Unable to generate htif bindings");

    // pma constants
    let pma = bindgen::Builder::default()
        .header(libdir_path.join("pma-defines.h").to_str().unwrap())
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

#[cfg(feature = "copy_uarch")]
fn copy_uarch(uarch_path: &PathBuf) {
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

#[cfg(feature = "download_uarch")]
fn download_uarch(uarch_path: &PathBuf) {
    //
    // Download `uarch-pristine-hash.c`
    //

    // get
    let data = reqwest::blocking::get(UARCH_PRISTINE_HASH_URL)
        .expect("error downloading uarch hash")
        .bytes()
        .expect("error getting uarch hash request body");

    // checksum
    let mut hasher = Sha1::new();
    hasher.update(&data);
    let result = hasher.finalize();
    assert_eq!(
        result[..],
        UARCH_PRISTINE_HASH_CHECKSUM,
        "uarch pristine hash checksum failed"
    );

    // write to file
    write_bytes_to_file(
        uarch_path.join("uarch-pristine-hash.c").to_str().unwrap(),
        data,
    )
    .expect("failed to write `uarch-pristine-hash.c`");

    //
    // Download `uarch-pristine-ram.c`
    //

    // get
    let data = reqwest::blocking::get(UARCH_PRISTINE_RAM_URL)
        .expect("error downloading uarch ram")
        .bytes()
        .expect("error getting uarch ram request body");

    // checksum
    let mut hasher = Sha1::new();
    hasher.update(&data);
    let result = hasher.finalize();
    assert_eq!(
        result[..],
        UARCH_PRISTINE_RAM_CHECKSUM,
        "uarch pristine ram checksum failed"
    );

    // write to file
    write_bytes_to_file(
        uarch_path.join("uarch-pristine-ram.c").to_str().unwrap(),
        data,
    )
    .expect("failed to write `uarch-pristine-ram.c`");
}

fn write_bytes_to_file(path: &str, data: Bytes) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .open(path)
        .expect(&format!("failed to open file {}", path));

    file.write_all(&data)?;
    file.flush() // Ensure all data is written to disk
}

fn clean(path: &PathBuf) {
    // clean build artifacts
    Command::new("make")
        .args(&["clean", "depclean ", "distclean"])
        .current_dir(path)
        .status()
        .expect("Failed to run setup `make clean depclean distclean`");

    Command::new("rm")
        .args(&["src/*o.tmp"])
        .current_dir(path)
        .status()
        .expect("Failed to delete src/*.o.tmp files");
}
