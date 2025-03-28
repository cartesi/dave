rollups_contracts_path := join("cartesi-rollups", "contracts")
prt_contracts_path := join("prt", "contracts")
tournament_path := join('src', 'tournament')
tournament_factories_path := join(tournament_path, 'factories')
tournament_concretes_path := join(tournament_path, 'concretes')

input_box_contract := join("lib", "rollups-contracts", "contracts", "inputs", "InputBox.sol:InputBox")
dave_consensus_contract := join("src", "DaveConsensus.sol:DaveConsensus")

multi_level_factory_contract := join(tournament_factories_path, 'MultiLevelTournamentFactory.sol:MultiLevelTournamentFactory')
top_tournament_factory_contract := join(tournament_factories_path, 'multilevel', 'TopTournamentFactory.sol:TopTournamentFactory')
middle_tournament_factory_contract := join(tournament_factories_path, 'multilevel', 'MiddleTournamentFactory.sol:MiddleTournamentFactory')
bottom_tournament_factory_contract := join(tournament_factories_path, 'multilevel', 'BottomTournamentFactory.sol:BottomTournamentFactory')
top_tournament_contract := join(tournament_concretes_path, 'TopTournament.sol:TopTournament')
middle_tournament_contract := join(tournament_concretes_path, "MiddleTournament.sol:MiddleTournament")
bottom_tournament_contract := join(tournament_concretes_path, "BottomTournament.sol:BottomTournament")

cwd := justfile_directory()
indexer_abis_folder := join(cwd, 'indexer', 'abis')
tmpDir := join(cwd, 'tmp')

[private]
@gen-rollups-contracts-abis:
	echo "{{ YELLOW + BOLD }}Prepare ABIs for rollup-contracts{{ NORMAL }}"
	cd ../{{rollups_contracts_path}} && \
	forge inspect \
		--json {{input_box_contract}} abi \
		| sed '1s/^/export const InputBox = /; $s/$/ as const/' > {{indexer_abis_folder}}/InputBox.ts
	echo "{{ GREEN }} InputBox.sol done!"
	cd ../{{rollups_contracts_path}} && \
	forge inspect \
		--json {{dave_consensus_contract}} abi \
		| sed '1s/^/export const DaveConsensus = /; $s/$/ as const/' > {{indexer_abis_folder}}/DaveConsensus.ts
	echo "{{ GREEN }} DaveConsensus.sol done!"

[private]
@gen-prt-factory-abis:
	cd ../{{prt_contracts_path}} && forge inspect --json {{multi_level_factory_contract}} abi \
	| sed '1s/^/export const MultiLevelTournamentFactory = /; $s/$/ as const/' > {{indexer_abis_folder}}/MultiLevelTournamentFactory.ts
	echo "{{ GREEN }} MultiLevelTournamentFactory.sol done!"
	cd ../{{prt_contracts_path}} && forge inspect --json {{top_tournament_factory_contract}} abi \
	| sed '1s/^/export const TopTournamentFactory = /; $s/$/ as const/' > {{indexer_abis_folder}}/TopTournamentFactory.ts
	echo "{{ GREEN }} TopTournamentFactory.sol done!"
	cd ../{{prt_contracts_path}} && forge inspect --json {{middle_tournament_factory_contract}} abi \
	| sed '1s/^/export const MiddleTournamentFactory = /; $s/$/ as const/' > {{indexer_abis_folder}}/MiddleTournamentFactory.ts
	echo "{{ GREEN }} MiddleTournamentFactory.sol done!"
	cd ../{{prt_contracts_path}} && forge inspect --json {{bottom_tournament_factory_contract}} abi \
	| sed '1s/^/export const BottomTournamentFactory = /; $s/$/ as const/' > {{indexer_abis_folder}}/BottomTournamentFactory.ts
	echo "{{ GREEN }} BottomTournamentFactory.sol done!"

[private]
@gen-prt-concrete-abis:
	cd ../{{prt_contracts_path}} && forge inspect --json {{top_tournament_contract}} abi \
	| sed '1s/^/export const TopTournament = /; $s/$/ as const/' > {{indexer_abis_folder}}/TopTournament.ts
	echo "{{ GREEN }} TopTournament.sol done!"
	cd ../{{prt_contracts_path}} && forge inspect --json {{middle_tournament_contract}} abi \
	| sed '1s/^/export const MiddleTournament = /; $s/$/ as const/' > {{indexer_abis_folder}}/MiddleTournament.ts
	echo "{{ GREEN }} MiddleTournament.sol done!" 
	cd ../{{prt_contracts_path}} && forge inspect --json {{bottom_tournament_contract}} abi \
	| sed '1s/^/export const BottomTournament = /; $s/$/ as const/' > {{indexer_abis_folder}}/BottomTournament.ts
	echo "{{ GREEN }} BottomTournament.sol done!"

[private]
@gen-prt-contracts-abi:
	echo "{{YELLOW + BOLD }}Prepare ABIs for prt-contracts{{NORMAL}}"
	just gen-prt-factory-abis
	just gen-prt-concrete-abis

[doc("Generate ABIs from rollups-contracts and prt.")]
[group("ABI")]
generate-abi: gen-rollups-contracts-abis gen-prt-contracts-abi
	@echo '{{CYAN + BOLD}}\nAll files created on: {{indexer_abis_folder}} {{ NORMAL }}\n'

