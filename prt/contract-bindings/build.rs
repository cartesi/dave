use std::{path::PathBuf, process::Command};

fn main() {
    let prt_path = PathBuf::from("../")
        .canonicalize()
        .expect("cannot canonicalize path");

    // make bindings
    Command::new("make")
        .args(&["bind"])
        .current_dir(&prt_path)
        .status()
        .expect("Failed to run `make bind`");

    // Setup reruns
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rerun-if-changed={}",
        prt_path.join("contracts/src").display()
    );
}
