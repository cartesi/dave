use std::{env, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    // Directory where `libcartesi.a` is located after it's built.
    let machine_dir_path = PathBuf::from("../../machine-emulator")
        // Canonicalize the path as `rustc-link-search` requires an absolute
        // path.
        .canonicalize()
        .expect("cannot canonicalize path");
    let libdir_path = machine_dir_path.join("src");
    println!("cargo:rerun-if-changed={}", libdir_path.to_str().unwrap());

    // Build `libcartesi.a`
    Command::new("make")
        .current_dir(&machine_dir_path)
        .args(&["submodules", "downloads", "dep"])
        .output()
        .expect("Failed to run setup `make submodules downloads dep`");
    Command::new("make")
        .current_dir(&machine_dir_path)
        .args(&["bundle-boost"])
        .output()
        .expect("Failed to run `make bundle-boost`");
    Command::new("make")
        .current_dir(&machine_dir_path)
        .args(&[
            "-C",
            "src",
            "release=yes",
            "libcartesi.a",
            "libcartesi_jsonrpc.a",
        ])
        .output()
        .expect("Failed to build `libcartesi.a`");

    // Tell cargo where to look for libraries, and which libraries to link
    println!("cargo:rustc-link-search={}", libdir_path.to_str().unwrap());
    println!("cargo:rustc-link-lib=static=cartesi");

    // Generate bindings
    let machine_bindings = bindgen::Builder::default()
        .header(libdir_path.join("machine-c-api.h").to_str().unwrap())
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("Unable to generate bindings");
    let htif = bindgen::Builder::default()
        .header(libdir_path.join("htif-defines.h").to_str().unwrap())
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("Unable to generate bindings");

    // Write the bindings to the $OUT_DIR/bindings.rs file.
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    machine_bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write machine bindings!");
    htif.write_to_file(out_path.join("htif.rs"))
        .expect("Couldn't write htif defines!");
}
