// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {DeploymentScript} from "../../script/Deployment.s.sol";

/// @dev The canonical provider's constructor arguments exactly as the
/// deployment script builds them for the current chain id.
contract ScriptProviderArguments is DeploymentScript {
    function providerArguments() external returns (bytes memory) {
        _registerChains();
        _registerChainKinds();
        return _canonicalProviderArguments();
    }
}

