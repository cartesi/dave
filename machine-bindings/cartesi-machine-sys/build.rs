use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rustc-link-lib=cartesi");

    let bindings = bindgen::Builder::default()
        .header("src/headers/machine-c-api.h")
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}