// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {DaveAppAddressCalculator} from "src/devnet/DaveAppAddressCalculator.sol";
import {IDaveAppAddressCalculator} from "src/devnet/IDaveAppAddressCalculator.sol";
import {IDaveAppFactory} from "src/IDaveAppFactory.sol";

contract DaveAppAddressCalculatorTest is Test {
    IDaveAppFactory daveAppFactoryMock;
    IDaveAppAddressCalculator daveAppAddressCalculator;

    function setUp() external {
        daveAppFactoryMock = IDaveAppFactory(vm.addr(1));
        daveAppAddressCalculator = new DaveAppAddressCalculator(daveAppFactoryMock);
    }

    function testCalculateDaveAppAddress(
        bytes32 templateHash,
        bytes32 salt,
        address appContractAddress,
        address daveContractAddress
    ) external {
        // First, mock the call to `calculateDaveAppAddress`,
        // returning the provided fuzzy arguments.
        vm.mockCall(
            address(daveAppFactoryMock),
            0 ether, // msg.value
            abi.encodeCall(IDaveAppFactory.calculateDaveAppAddress, (templateHash, salt)),
            abi.encode(appContractAddress, daveContractAddress)
        );

        // Then, start recording logs.
        vm.recordLogs();

        // Call the calculator.
        daveAppAddressCalculator.calculateDaveAppAddress(templateHash, salt);

        // Retrieve the EVM logs emitted in the call.
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 addressCalculationCount;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (
                log.emitter == address(daveAppAddressCalculator)
                    && log.topics[0] == IDaveAppAddressCalculator.AddressCalculation.selector
            ) {
                ++addressCalculationCount;
                (bytes32 arg0, bytes32 arg1, address arg2, address arg3) =
                    abi.decode(log.data, (bytes32, bytes32, address, address));
                assertEq(arg0, templateHash);
                assertEq(arg1, salt);
                assertEq(arg2, appContractAddress);
                assertEq(arg3, daveContractAddress);
            }
        }

        // Ensure a `AddressCalculation` event was emitted.
        assertEq(addressCalculationCount, 1);
    }
}
