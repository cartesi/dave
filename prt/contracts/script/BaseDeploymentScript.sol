// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {Create2} from "@openzeppelin-contracts-5.5.0/utils/Create2.sol";

import {Script} from "forge-std-1.9.6/src/Script.sol";

/// @notice A base contract for deployment scripts.
/// @dev Deployments are serialized to JSON files containing the
/// contract name and address, and stored in chain-specific directories
/// per project. They can be stored (requires read-write fs permission)
/// and loaded from other projects (requires read fs permission).
abstract contract BaseDeploymentScript is Script {
    /// @notice Deterministically deploy a contract.
    /// @param creationCode The creation code of the contract
    /// @param encodedConstructorArgs The ABI-encoded constructor arguments
    /// @return deployment The deployment address
    function _create2(
        bytes memory creationCode,
        bytes memory encodedConstructorArgs
    ) internal returns (address deployment) {
        bytes32 salt;
        bytes memory initCode =
            abi.encodePacked(creationCode, encodedConstructorArgs);
        deployment = vm.computeCreate2Address(salt, keccak256(initCode));
        if (deployment.code.length == 0) {
            vm.assertEq(deployment, Create2.deploy(0, salt, initCode));
        }
    }

    /// @notice Store a deployment in a JSON file.
    /// @param contractName The contract name
    /// @param deployment The deployment address
    /// @return depoyment The deployment address
    function _storeDeployment(string memory contractName, address deployment)
        internal
        returns (address)
    {
        string memory deploymentStr = vm.toString(deployment);
        string memory objectKey =
            string.concat(contractName, "@", deploymentStr);
        string memory json;
        json = vmSafe.serializeAddress(objectKey, "address", deployment);
        json = vmSafe.serializeString(objectKey, "contractName", contractName);
        string memory dir = _getCurrentChainDeploymentsDir(".");
        vm.createDir(dir, true);
        string memory path = _getDeploymentFilePath(dir, contractName);
        vmSafe.writeJson(json, path);
        return deployment;
    }

    /// @notice Load a deployment from a JSON file.
    /// @param projectRoot The project root path
    /// @param contractName The contract name
    /// @return deployment The deployment address
    function _loadDeployment(
        string memory projectRoot,
        string memory contractName
    ) internal view returns (address deployment) {
        string memory dir = _getCurrentChainDeploymentsDir(projectRoot);
        string memory path = _getDeploymentFilePath(dir, contractName);
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vmSafe.readFile(path);
        return vmSafe.parseJsonAddress(json, ".address");
    }

    /// @notice Get the deployment directory of a project given the current chain.
    /// @param projectRoot The project root path
    /// @return dir The project's deployments directory for the current chain
    function _getCurrentChainDeploymentsDir(string memory projectRoot)
        internal
        view
        returns (string memory dir)
    {
        dir = string.concat(
            projectRoot, "/deployments/", vm.toString(block.chainid)
        );
    }

    /// @notice Get the path of a deployment file given the directory and contract name.
    /// @param dir The deployment directory (see `_getCurrentChainDeploymentsDir`)
    /// @param contractName The contract name
    /// @return path The deployment file path
    function _getDeploymentFilePath(
        string memory dir,
        string memory contractName
    ) internal pure returns (string memory path) {
        path = string.concat(dir, "/", contractName, ".json");
    }
}
