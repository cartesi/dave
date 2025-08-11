// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.27;

contract Refundable {
    uint256 constant BOND_VALUE = 1 ether;

    // sum the heights of each tournament and divide by 2
    // plus 1 (for the step)
    uint256 constant MAX_NUM_INTERACTIONS_PER_PLAYER = 47;

    // A constant in the Ethereum protocol
    uint256 constant TX_BASE_GAS = 21000;

    // MEV tips
    uint256 constant PRIORITY_FEE_PER_GAS = 10 gwei;

    /// @notice Failed to refund a contract sender
    error FailedRefund();

    /// @notice Reentrancy detected, the contract is locked
    error ReentrancyDetected();

    bool private locked;

    /// @notice Refunds the message sender with the amount
    /// of Ether wasted on gas on this function call plus
    /// a profit, capped by the current contract balance
    // and the division between the bond value and the
    // max number of interactions per player.
    modifier refundable() {
        if (locked) revert ReentrancyDetected();
        locked = true;

        uint256 gasBefore = gasleft();
        _;
        uint256 gasAfter = gasleft();

        uint256 refundValue = min(
            address(this).balance,
            BOND_VALUE / MAX_NUM_INTERACTIONS_PER_PLAYER,
            (TX_BASE_GAS + gasBefore - gasAfter)
                * (tx.gasprice + PRIORITY_FEE_PER_GAS)
        );

        if (refundValue > 0) {
            (bool success,) = msg.sender.call{value: refundValue}("");
            require(success, FailedRefund());
        }

        locked = false;
    }

    /// @notice Returns the minimum of three values
    /// @param a First value
    /// @param b Second value
    /// @param c Third value
    /// @return The minimum value
    function min(uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (uint256)
    {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
}
