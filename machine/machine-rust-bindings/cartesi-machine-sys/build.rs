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
        .args(&["submodules", "downloads", "dep"])
        .current_dir(&machine_dir_path)
        .output()
        .expect("Failed to run setup `make submodules downloads dep`");
    Command::new("make")
        .args(&["bundle-boost"])
        .current_dir(&machine_dir_path)
        .output()
        .expect("Failed to run `make bundle-boost`");
    Command::new("make")
        .args(&[
            "-C",
            "src",
            "release=yes",
            "libcartesi.a",
            "libcartesi_jsonrpc.a",
        ])
        .current_dir(&machine_dir_path)
        .output()
        .expect("Failed to build `libcartesi.a` and/or `libcartesi_jsonrpc.a`");

    // Tell Cargo where to look for libraries
    println!("cargo:rustc-link-search={}", libdir_path.to_str().unwrap());

    // Static link
    if !cfg!(remote_machine) {
        println!("cargo:rustc-link-lib=static=cartesi");
    } else {
        println!("cargo:rustc-link-lib=static=cartesi_jsonrpc");
    }

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

    // Write the bindings to the `$OUT_DIR/bindings.rs` and `$OUT_DIR/htif.rs` files.
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    machine_bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write machine bindings!");
    htif.write_to_file(out_path.join("htif.rs"))
        .expect("Couldn't write htif defines!");
}
