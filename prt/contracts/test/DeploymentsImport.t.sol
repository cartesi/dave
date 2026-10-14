// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {BaseDeploymentScript} from "../script/BaseDeploymentScript.sol";

contract ImportHarness is BaseDeploymentScript {
    function importFrom(string memory projectRoot) external {
        _importDeployments(projectRoot);
    }

    function load(string memory projectRoot, string memory name)
        external
        view
        returns (address)
    {
        return _loadDeployment(projectRoot, name);
    }
}

/// @dev Modality "deployment", question 2: what a stale or planted file in
/// `deployments/<chainid>` does to a release. Dave's script imports every
/// TXT and JSON file of the PRT project and of the rollups dependency for the
/// current chain, then loads `MultiLevelTournamentFactory` by name
/// (cartesi-rollups/contracts/script/Deployment.s.sol:12-17).
///
/// - Refuted: a planted file that names an imported contract with another
///   address cannot redirect silently; the duplicate fails the import.
/// - Lead: a file under a new name is imported silently and re-published in
///   the importing project's deployments; and when the PRT step does not run
///   first (Dave's script alone), a stale or planted factory file is the one
///   Dave wires. Both change only Dave's CREATE2 address, so the check that
///   catches them is the comparison with the release asset, which the
///   missing deployment runbook (docs/plans/audit-readiness.md, item 4)
///   should carry.
contract DeploymentsImportTest is Test {
    address constant REAL = address(0x1111);
    address constant PLANTED = address(0x2222);

    // Forge runs a contract's tests in parallel over one filesystem, so each
    // test owns a chain id and therefore its own directories.
    string source;
    string sourceDir;
    string sinkDir;

    function _setUpChain(uint256 chainId) internal {
        vm.chainId(chainId);
        string memory id = vm.toString(chainId);
        source = string.concat("deployments/audit-source-", id);
        sourceDir = string.concat(source, "/deployments/", id);
        sinkDir = string.concat("deployments/", id);
        _clean();
        vm.createDir(sourceDir, true);
        _txt("MultiLevelTournamentFactory", REAL);
        _json(
            "MultiLevelTournamentFactory.json",
            "MultiLevelTournamentFactory",
            REAL
        );
    }

    function testRefutedPlantedDuplicateRedirectsFactory() public {
        _setUpChain(987_654_001);
        _json("zz.json", "MultiLevelTournamentFactory", PLANTED);
        ImportHarness h = new ImportHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseDeploymentScript.ContractNameConflict.selector,
                "MultiLevelTournamentFactory",
                REAL,
                PLANTED
            )
        );
        h.importFrom(source);
        _clean();
    }

    function testTraceStaleNameIsImportedSilently() public {
        _setUpChain(987_654_002);
        _txt("TopTournamentFactory", PLANTED);
        ImportHarness h = new ImportHarness();
        h.importFrom(source);
        assertEq(h.load(".", "MultiLevelTournamentFactory"), REAL);
        assertEq(h.load(".", "TopTournamentFactory"), PLANTED);
        assertTrue(
            vm.exists(string.concat(sinkDir, "/TopTournamentFactory.txt"))
        );
        _clean();
    }

    function testTraceLoneStaleFactoryFileIsWired() public {
        // Dave's script run without the PRT step: nothing rewrites the file.
        _setUpChain(987_654_003);
        _txt("MultiLevelTournamentFactory", PLANTED);
        vm.removeFile(
            string.concat(sourceDir, "/MultiLevelTournamentFactory.json")
        );
        ImportHarness h = new ImportHarness();
        h.importFrom(source);
        assertEq(h.load(".", "MultiLevelTournamentFactory"), PLANTED);
        _clean();
    }

    function _txt(string memory name, address a) internal {
        vm.writeFile(
            string.concat(sourceDir, "/", name, ".txt"), vm.toString(a)
        );
    }

    function _json(string memory file, string memory name, address a) internal {
        vm.writeFile(
            string.concat(sourceDir, "/", file),
            string.concat(
                '{"address":"', vm.toString(a), '","contractName":"', name, '"}'
            )
        );
    }

    function _clean() internal {
        if (vm.exists(source)) vm.removeDir(source, true);
        if (vm.exists(sinkDir)) vm.removeDir(sinkDir, true);
    }
}
