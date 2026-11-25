// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {IOutputsMerkleRootValidator} from "cartesi-rollups-contracts-3.0.0/src/consensus/IOutputsMerkleRootValidator.sol";
import {RollupsTest} from "cartesi-rollups-contracts-3.0.0/test/util/RollupsTest.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {DaveAppFactory} from "src/DaveAppFactory.sol";

/// @notice The factory's address prediction, with no deployment: the views
/// validate nothing, so no argument is assumed valid. What a reserved
/// address is worth, and that the pair lands on the prediction, are held
/// elsewhere: the first by the application factory's own tests, the second
/// by `DaveAppFactoryTest.testNewDaveApp`.
contract DaveAppFactorySquattingTest is RollupsTest {
    /// @notice The arguments of `calculateDaveAppAddress`.
    struct Arguments {
        bytes32 templateHash;
        uint256 claimStagingPeriod;
        address sentryManager;
        address[] sentries;
        WithdrawalConfig withdrawalConfig;
        bytes32 salt;
    }

    DaveAppFactory factory;
    ITournamentFactory constant TOURNAMENT_FACTORY = ITournamentFactory(address(0x100));
    IOutputsMerkleRootValidator constant NO_VALIDATOR = IOutputsMerkleRootValidator(address(0));

    function setUp() external {
        factory = new DaveAppFactory(_contracts.core.inputBox, _contracts.core.applicationFactory, TOURNAMENT_FACTORY);
    }

    /// @notice The salt the factory hands the application factory, which
    /// binds the consensus settings.
    function _applicationSalt(
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] memory sentries,
        bytes32 salt
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(claimStagingPeriod, sentryManager, sentries, salt));
    }

    /// @notice The predicted application address is the one the application
    /// factory reserves for the Dave factory under that salt, whatever the
    /// arguments: neither view validates them, so none is assumed valid.
    function testFuzzThePredictedApplicationIsReservedForTheFactory(
        bytes32 templateHash,
        uint256 claimStagingPeriod,
        address sentryManager,
        address[] calldata sentries,
        WithdrawalConfig calldata withdrawalConfig,
        bytes32 salt
    ) external view {
        (address predicted,) = factory.calculateDaveAppAddress(
            templateHash, claimStagingPeriod, sentryManager, sentries, withdrawalConfig, salt
        );
        assertEq(
            predicted,
            _contracts.core.applicationFactory
                .calculateReservedApplicationAddress(
                    NO_VALIDATOR,
                    address(factory),
                    templateHash,
                    _contracts.core.inputBox,
                    withdrawalConfig,
                    _applicationSalt(claimStagingPeriod, sentryManager, sentries, salt),
                    address(factory)
                )
        );
    }

    // Each argument alone moves both addresses, so no other value of it can
    // land on a pair's application or its consensus. One argument moves per
    // test and the other five stay: two argument sets drawn apart never
    // differ in one field only, which is the draw that catches an argument
    // left out of an address. The test above cannot catch that either, since
    // its salt mirrors the factory's.

    function testFuzzTheTemplateHashMovesBothAddresses(Arguments calldata arguments, bytes32 otherTemplateHash)
        external
        view
    {
        vm.assume(otherTemplateHash != arguments.templateHash);
        Arguments memory other = arguments;
        other.templateHash = otherTemplateHash;
        _assertBothAddressesMove(arguments, other);
    }

    function testFuzzTheClaimStagingPeriodMovesBothAddresses(
        Arguments calldata arguments,
        uint256 otherClaimStagingPeriod
    ) external view {
        vm.assume(otherClaimStagingPeriod != arguments.claimStagingPeriod);
        Arguments memory other = arguments;
        other.claimStagingPeriod = otherClaimStagingPeriod;
        _assertBothAddressesMove(arguments, other);
    }

    function testFuzzTheSentryManagerMovesBothAddresses(Arguments calldata arguments, address otherSentryManager)
        external
        view
    {
        vm.assume(otherSentryManager != arguments.sentryManager);
        Arguments memory other = arguments;
        other.sentryManager = otherSentryManager;
        _assertBothAddressesMove(arguments, other);
    }

    function testFuzzTheSentriesMoveBothAddresses(Arguments calldata arguments, address[] calldata otherSentries)
        external
        view
    {
        vm.assume(keccak256(abi.encode(otherSentries)) != keccak256(abi.encode(arguments.sentries)));
        Arguments memory other = arguments;
        other.sentries = otherSentries;
        _assertBothAddressesMove(arguments, other);
    }

    function testFuzzTheWithdrawalConfigMovesBothAddresses(
        Arguments calldata arguments,
        WithdrawalConfig calldata otherWithdrawalConfig
    ) external view {
        vm.assume(keccak256(abi.encode(otherWithdrawalConfig)) != keccak256(abi.encode(arguments.withdrawalConfig)));
        Arguments memory other = arguments;
        other.withdrawalConfig = otherWithdrawalConfig;
        _assertBothAddressesMove(arguments, other);
    }

    function testFuzzTheSaltMovesBothAddresses(Arguments calldata arguments, bytes32 otherSalt) external view {
        vm.assume(otherSalt != arguments.salt);
        Arguments memory other = arguments;
        other.salt = otherSalt;
        _assertBothAddressesMove(arguments, other);
    }

    function _predict(Arguments memory arguments) private view returns (address, address) {
        return factory.calculateDaveAppAddress(
            arguments.templateHash,
            arguments.claimStagingPeriod,
            arguments.sentryManager,
            arguments.sentries,
            arguments.withdrawalConfig,
            arguments.salt
        );
    }

    function _assertBothAddressesMove(Arguments memory arguments, Arguments memory other) private view {
        (address application, address consensus) = _predict(arguments);
        (address otherApplication, address otherConsensus) = _predict(other);
        assertNotEq(application, otherApplication, "the application address did not move");
        assertNotEq(consensus, otherConsensus, "the consensus address did not move");
    }
}
