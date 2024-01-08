use convert_case::{Case, Casing};
use ethers_contract_abigen::Abigen;
use foundry_compilers::remappings::Remapping;
use foundry_compilers::{Project, ProjectPathsConfig};
use serde_json;
use std::path::{Path, PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    generate_contract_bidings()?;
    Ok(())
}

fn generate_contract_bidings() -> Result<(), Box<dyn std::error::Error>> {
    let project_path = Path::new(env!("CARGO_MANIFEST_DIR"));
    let contract_rel_path = "../../permissionless-arbitration/contracts";
    let step_rel_path = "../../machine-emulator-sdk/solidity-step/";
    let contract_root_path = project_path.join(contract_rel_path);
    let contract_src_files = vec![
        "LeafTournament".to_string(),
        "NonLeafTournament".to_string(),
        "RootTournament".to_string(),
        "NonRootTournament".to_string(),
        "Tournament".to_string(),
    ];

    let paths = ProjectPathsConfig::builder()
        .root(contract_root_path.as_path())
        .remapping(Remapping {
            context: None,
            name: "step/".to_string(),
            path: step_rel_path.to_string(),
        })
        .build()?;

    let project = Project::builder()
        .paths(paths)
        .allowed_path(step_rel_path)
        .build()?;

    project
        .compile_files(
            contract_src_files
                .iter()
                .map(|f| {
                    contract_root_path
                        .join("src/tournament/abstracts")
                        .join(format!("{}.sol", f))
                })
                .collect::<Vec<PathBuf>>(),
        )?
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
    project.rerun_if_sources_changed();

    Ok(())
}
