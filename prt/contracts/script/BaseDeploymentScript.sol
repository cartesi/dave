// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {Create2} from "@openzeppelin-contracts-5.5.0/utils/Create2.sol";

import {Script} from "forge-std-1.9.6/src/Script.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

/// @notice A base contract for deployment scripts.
/// @dev Deployments are serialized to files named after the contract and
/// stored in chain-specific directories per project. Every deployment is
/// written in two formats: a plaintext (TXT) file containing only the
/// address, and a JSON file containing the address and the contract name.
/// The TXT format is the canonical one, and the only one read back by
/// `_loadDeployment`. The JSON format is deprecated and kept only so that
/// clients still reading it can migrate at their own pace; it will be
/// removed once they have. They can be stored (requires read-write fs
/// permission) and loaded from other projects (requires read fs permission).
abstract contract BaseDeploymentScript is Script {
    /// @notice The extension of plaintext deployment files.
    string constant TXT_EXTENSION = ".txt";

    /// @notice The extension of JSON deployment files.
    /// @dev Deprecated. See the contract-level documentation.
    string constant JSON_EXTENSION = ".json";

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
    /// @return deployment The deployment address
    /// @dev Writes the deployment in both the TXT and the JSON formats.
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

        string memory dir = _getCurrentChainDeploymentsDir(".");
        vm.createDir(dir, true);
        _writeTxtDeployment(dir, contractName, deployment);
        _writeJsonDeployment(dir, contractName, deployment);
        return deployment;
    }

    /// @notice Write a deployment to a TXT file, which holds the
    /// deployment address and nothing else.
    /// @param dir The deployment directory
    /// @param contractName The contract name
    /// @param deployment The deployment address
    function _writeTxtDeployment(
        string memory dir,
        string memory contractName,
        address deployment
    ) private {
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        vmSafe.writeFile(
            _getDeploymentFilePath(dir, contractName, TXT_EXTENSION),
            vmSafe.toString(deployment)
        );
    }

    /// @notice Write a deployment to a JSON file, which holds the
    /// deployment address along with the contract name.
    /// @param dir The deployment directory
    /// @param contractName The contract name
    /// @param deployment The deployment address
    /// @dev Deprecated. See the contract-level documentation.
    function _writeJsonDeployment(
        string memory dir,
        string memory contractName,
        address deployment
    ) private {
        string memory objectKey = string.concat(
            contractName, "@", vmSafe.toString(deployment)
        );
        string memory json;
        json = vmSafe.serializeAddress(objectKey, "address", deployment);
        json = vmSafe.serializeString(objectKey, "contractName", contractName);
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        vmSafe.writeFile(
            _getDeploymentFilePath(dir, contractName, JSON_EXTENSION), json
        );
    }

    /// @notice Load a deployment from a project.
    /// @param projectRoot The project root path
    /// @param contractName The contract name
    /// @return deployment The deployment address
    /// @dev Reads the TXT file. The JSON file is deprecated and, even
    /// though it is still written, it is no longer read back.
    function _loadDeployment(
        string memory projectRoot,
        string memory contractName
    ) internal view returns (address deployment) {
        string memory dir = _getCurrentChainDeploymentsDir(projectRoot);
        return _readTxtDeployment(
            _getDeploymentFilePath(dir, contractName, TXT_EXTENSION)
        );
    }

    /// @notice Read a deployment address from a TXT file.
    /// @param path The TXT file path
    /// @return deployment The deployment address
    /// @dev The file is expected to hold the address and nothing else,
    /// with no trailing newline, as written by `_writeTxtDeployment`.
    function _readTxtDeployment(string memory path)
        private
        view
        returns (address deployment)
    {
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        return vmSafe.parseAddress(vmSafe.readFile(path));
    }

    /// @notice Read a deployment address from a JSON file.
    /// @param path The JSON file path
    /// @return contractName The contract name
    /// @return deployment The deployment address
    /// @dev Deprecated. See the contract-level documentation.
    function _readJsonDeployment(string memory path)
        private
        view
        returns (string memory contractName, address deployment)
    {
        /// forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vmSafe.readFile(path);
        contractName = vmSafe.parseJsonString(json, ".contractName");
        deployment = vmSafe.parseJsonAddress(json, ".address");
    }

    /// @notice Import all deployments from a project.
    /// @param projectRoot The project root path
    /// @dev The traversal of the deployments directory is shallow (maxDepth = 1).
    /// Symbolic links are not followed to avoid unbounded recursion.
    /// Both TXT and JSON files are imported, since a project may have
    /// migrated to the TXT format already, or may not have yet. A contract
    /// deployed in both formats is therefore imported twice; the second
    /// import is a no-op if both files agree, and raises a
    /// `ContractNameConflict` error if they do not. Files with any other
    /// extension are not deployment artifacts, and are skipped.
    function _importDeployments(string memory projectRoot) internal {
        string memory dir = _getCurrentChainDeploymentsDir(projectRoot);
        Vm.DirEntry[] memory dirEntries = vm.readDir(dir, 1, false);
        for (uint256 i; i < dirEntries.length; ++i) {
            Vm.DirEntry memory dirEntry = dirEntries[i];
            if (!vm.isFile(dirEntry.path)) {
                continue;
            }
            if (_hasSuffix(dirEntry.path, TXT_EXTENSION)) {
                // A TXT file holds no contract name,
                // so it is taken from the file name instead.
                string memory contractName =
                    _getContractNameFromFilePath(dirEntry.path, TXT_EXTENSION);
                _storeDeployment(
                    contractName, _readTxtDeployment(dirEntry.path)
                );
            } else if (_hasSuffix(dirEntry.path, JSON_EXTENSION)) {
                (string memory contractName, address deployment) =
                    _readJsonDeployment(dirEntry.path);
                _storeDeployment(contractName, deployment);
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

    /// @notice Get the path of a deployment file given the directory,
    /// the contract name and the file extension.
    /// @param dir The deployment directory (see `_getCurrentChainDeploymentsDir`)
    /// @param contractName The contract name
    /// @param extension The file extension, including the leading dot
    /// @return path The deployment file path
    function _getDeploymentFilePath(
        string memory dir,
        string memory contractName,
        string memory extension
    ) internal pure returns (string memory path) {
        path = string.concat(dir, "/", contractName, extension);
    }

    /// @notice Get the contract name a deployment file is named after.
    /// @param path The deployment file path
    /// @param extension The file extension, including the leading dot
    /// @return contractName The contract name
    /// @dev Assumes `path` ends with `extension` (see `_hasSuffix`).
    /// The result is not validated here: `_storeDeployment` rejects it
    /// through `_isContractNameValid` if the file was named arbitrarily.
    function _getContractNameFromFilePath(
        string memory path,
        string memory extension
    ) internal pure returns (string memory contractName) {
        bytes memory pathBytes = bytes(path);
        uint256 end = pathBytes.length - bytes(extension).length;

        // The name starts right after the last path separator, if any.
        uint256 start;
        for (uint256 i = end; i > 0; --i) {
            if (pathBytes[i - 1] == "/") {
                start = i;
                break;
            }
        }

        bytes memory nameBytes = new bytes(end - start);
        for (uint256 i; i < nameBytes.length; ++i) {
            nameBytes[i] = pathBytes[start + i];
        }
        contractName = string(nameBytes);
    }

    /// @notice Check whether a string ends with a given suffix.
    /// @param str The string
    /// @param suffix The suffix
    /// @return True if `str` ends with `suffix`, false otherwise
    function _hasSuffix(string memory str, string memory suffix)
        internal
        pure
        returns (bool)
    {
        bytes memory strBytes = bytes(str);
        bytes memory suffixBytes = bytes(suffix);

        if (strBytes.length < suffixBytes.length) {
            return false;
        }

        uint256 offset = strBytes.length - suffixBytes.length;
        for (uint256 i; i < suffixBytes.length; ++i) {
            if (strBytes[offset + i] != suffixBytes[i]) {
                return false;
            }
        }

        return true;
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
        if (!((firstChar >= "A" && firstChar <= "Z")
                    || (firstChar >= "a" && firstChar <= "z")
                    || firstChar == "_" || firstChar == "$")) {
            return false;
        }

        // Check remaining characters: must be a-z, A-Z, 0-9, _, or $
        for (uint256 i = 1; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            if (!((char >= "A" && char <= "Z") || (char >= "a" && char <= "z")
                        || (char >= "0" && char <= "9") || char == "_"
                        || char == "$")) {
                return false;
            }
        }

        return true;
    }
}
