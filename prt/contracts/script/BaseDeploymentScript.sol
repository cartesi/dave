// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {Create2} from "@openzeppelin-contracts-5.5.0/utils/Create2.sol";

import {Script} from "forge-std-1.9.6/src/Script.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

/// @notice A base contract for deployment scripts.
/// @dev Deployments are serialized to JSON files containing the
/// contract name and address, and stored in chain-specific directories
/// per project. They can be stored (requires read-write fs permission)
/// and loaded from other projects (requires read fs permission).
abstract contract BaseDeploymentScript is Script {
    /// @notice The set of deployed contract names of the current project.
    mapping(string => bool) private _wasContractDeployed;

    /// @notice The set of deployments of the current project, indexed by contract name.
    mapping(string => address) private _deploymentByContractName;

    /// @notice This error is raised whenever `_storeDeployment` is called
    /// for an invalid contract name. See `_isContractNameValid` for more
    /// information on the validation criteria.
    error InvalidContractName(string contractName);

    /// @notice This error is raised whenever `_storeDeployment` is called
    /// for a contract that was already deployed before.
    /// @param contractName The contract name
    /// @param storedDeployment The deployment address that was stored already
    /// @param newDeployment The deployment address that being stored
    error ContractNameConflict(
        string contractName, address storedDeployment, address newDeployment
    );

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

    /// @notice Store a deployment in the current project.
    /// @param contractName The contract name
    /// @param deployment The deployment address
    /// @return depoyment The deployment address
    function _storeDeployment(string memory contractName, address deployment)
        internal
        returns (address)
    {
        require(
            _isContractNameValid(contractName),
            InvalidContractName(contractName)
        );

        if (_wasContractDeployed[contractName]) {
            address oldDeployment = _deploymentByContractName[contractName];
            require(
                oldDeployment == deployment,
                ContractNameConflict(contractName, oldDeployment, deployment)
            );
            return deployment; // ensures idempotency
        }

        _wasContractDeployed[contractName] = true;
        _deploymentByContractName[contractName] = deployment;

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

    /// @notice Load a deployment from a project.
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

    /// @notice Import all deployments from a project.
    /// @param projectRoot The project root path
    /// @dev The traversal of the deployments directory is shallow (maxDepth = 1).
    /// Symbolic links are not followed to avoid unbounded recursion.
    function _importDeployments(string memory projectRoot) internal {
        string memory dir = _getCurrentChainDeploymentsDir(projectRoot);
        Vm.DirEntry[] memory dirEntries = vm.readDir(dir, 1, false);
        for (uint256 i; i < dirEntries.length; ++i) {
            Vm.DirEntry memory dirEntry = dirEntries[i];
            if (vm.isFile(dirEntry.path)) {
                /// forge-lint: disable-next-line(unsafe-cheatcode)
                string memory json = vmSafe.readFile(dirEntry.path);
                _storeDeployment(
                    vmSafe.parseJsonString(json, ".contractName"),
                    vmSafe.parseJsonAddress(json, ".address")
                );
            }
        }
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

    /// @notice Checks if a contract name is valid according to Solidity naming rules
    /// @param contractName The contract name to validate
    /// @return True if the contract name is valid, false otherwise
    /// @dev Valid names match the regex `[a-zA-Z_$][a-zA-Z0-9_$]*`
    function _isContractNameValid(string memory contractName)
        internal
        pure
        returns (bool)
    {
        bytes memory nameBytes = bytes(contractName);

        // Empty string is invalid
        if (nameBytes.length == 0) {
            return false;
        }

        // Check first character: must be a-z, A-Z, _, or $
        bytes1 firstChar = nameBytes[0];
        if (!((firstChar >= 0x41 && firstChar <= 0x5A) // A-Z
                    || (firstChar >= 0x61 && firstChar <= 0x7A) // a-z
                    || firstChar == 0x5F // _
                    || firstChar == 0x24 // $
            )) {
            return false;
        }

        // Check remaining characters: must be a-z, A-Z, 0-9, _, or $
        for (uint256 i = 1; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            if (!((char >= 0x41 && char <= 0x5A) // A-Z
                        || (char >= 0x61 && char <= 0x7A) // a-z
                        || (char >= 0x30 && char <= 0x39) // 0-9
                        || char == 0x5F // _
                        || char == 0x24 // $
                )) {
                return false;
            }
        }

        return true;
    }
}
