// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IDaveAppAddressCalculator} from "./IDaveAppAddressCalculator.sol";
import {IDaveAppFactory} from "src/IDaveAppFactory.sol";

contract DaveAppAddressCalculator is IDaveAppAddressCalculator {
    IDaveAppFactory immutable _DAVE_APP_FACTORY;

    constructor(IDaveAppFactory daveAppFactory) {
        _DAVE_APP_FACTORY = daveAppFactory;
    }

    function calculateDaveAppAddress(bytes32 templateHash, bytes32 salt) external override {
        address appContractAddress;
        address daveConsensusAddress;

        (appContractAddress, daveConsensusAddress) = _DAVE_APP_FACTORY.calculateDaveAppAddress(templateHash, salt);

        emit AddressCalculation(templateHash, salt, appContractAddress, daveConsensusAddress);
    }
}
