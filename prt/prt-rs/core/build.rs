use convert_case::{Case, Casing};
use ethers_contract_abigen::Abigen;
use foundry_compilers::remappings::Remapping;
use foundry_compilers::{Project, ProjectPathsConfig};
use serde_json;
use std::path::Path;

macro_rules! p {
    ($($tokens: tt)*) => {
        println!("cargo:warning={}", format!($($tokens)*))
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    generate_contract_bindings()?;
    Ok(())
}

// TODO: polish this function
fn generate_contract_bindings() -> Result<(), Box<dyn std::error::Error>> {
    let project_path = Path::new(env!("CARGO_MANIFEST_DIR"));
    let permissionless_contract_path = project_path.join("../../contracts").canonicalize().unwrap();
    let solidity_step_path = project_path
        .join("../../../machine-emulator-sdk/solidity-step/")
        .canonicalize()
        .unwrap();
    let contract_src_files = vec![
        "LeafTournament".to_string(),
        "NonLeafTournament".to_string(),
        "RootTournament".to_string(),
        "NonRootTournament".to_string(),
        "Tournament".to_string(),
    ];

    let paths = ProjectPathsConfig::builder()
        .root(permissionless_contract_path.clone())
        .remapping(Remapping {
            context: None,
            name: "step/".to_string(),
            path: solidity_step_path.to_str().unwrap().to_string(),
        })
        .remapping(Remapping {
            context: None,
            name: "forge-std/".to_string(),
            path: "lib/forge-std/src/".to_string(),
        })
        .remapping(Remapping {
            context: None,
            name: "ds-test/".to_string(),
            path: "lib/forge-std/lib/ds-test/src/".to_string(),
        })
        .build()?;

    let project = Project::builder()
        .paths(paths)
        .allowed_path(solidity_step_path.to_str().unwrap())
        .build()?;

    project
        .compile()?
        .output()
        .errors
        .iter()
        .for_each(|f| p!("{}", f));

    project
        .compile()?
        .artifacts()
        .filter(|artifact| {
            contract_src_files
                .iter()
                .any(|src| src.find(&artifact.0).is_some())
        })
        .for_each(|(contract, artifact)| {
            let binding_file = format!("src/contract/{}.rs", contract.to_case(Case::Snake));
            Abigen::new(
                &contract,
                serde_json::to_string(artifact.abi.as_ref().expect("abi not found"))
                    .expect("fail to serialize abi"),
            )
            .expect("fail to construct abi builder")
            .generate()
            .expect("fail to generate binding")
            .write_to_file(project_path.join(binding_file))
            .expect("fail to write binding");
        });

    // Tell Cargo that if a source file changes, to rerun this build script.
    println!(
        "cargo:rerun-if-changed={}",
        permissionless_contract_path.display()
    );

    Ok(())
}
