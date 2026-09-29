// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Time} from "prt-contracts/tournament/libs/Time.sol";

/// @notice The dispute clock model in wall-clock terms, converted to the block
/// counts that tournament clocks use (docs/dimensioning.md).
/// @dev A correct commitment must survive `censorship` seconds of adversarial
/// delay in total. Every honest action lands within `inclusion` seconds, and
/// joining an inner tournament first takes `commitment` seconds to build the
/// commitment. Responses are discounted by one inclusion. A child that returns
/// its winner refills it by up to one refill: the build plus two inclusions,
/// for the join and for the propagation. The root allowance is the censorship
/// budget, one inclusion for the root join, and one refill per inner level:
/// the delegations a correct commitment may have pending on its path.
library ClockBudgets {
    error BlockTimeCannotBeZero();

    struct Model {
        uint64 blockMilliseconds;
        uint64 censorshipSeconds;
        uint64 inclusionSeconds;
        uint64 commitmentSeconds;
    }

    function responseBudget(Model memory model)
        internal
        pure
        returns (Time.Duration)
    {
        return _blocks(model.inclusionSeconds, model.blockMilliseconds);
    }

    function commitmentBudget(Model memory model)
        internal
        pure
        returns (Time.Duration)
    {
        return _blocks(model.commitmentSeconds, model.blockMilliseconds);
    }

    /// @notice What a parent refills, at most, when its child returns the
    /// winner; winInnerTournament computes the same sum from its row.
    function refill(Model memory model) internal pure returns (Time.Duration) {
        return Time.Duration
            .wrap(
                Time.Duration.unwrap(commitmentBudget(model)) + 2
                    * Time.Duration.unwrap(responseBudget(model))
            );
    }

    /// @dev Each term converts separately, so the allowance holds exactly
    /// `levels - 1` of the refills winInnerTournament grants.
    function maxAllowance(Model memory model, uint64 levels)
        internal
        pure
        returns (Time.Duration)
    {
        return Time.Duration
            .wrap(
                Time.Duration
                    .unwrap(
                        _blocks(
                            model.censorshipSeconds, model.blockMilliseconds
                        )
                    ) + Time.Duration.unwrap(responseBudget(model))
                + (levels - 1) * Time.Duration.unwrap(refill(model))
            );
    }

    /// @dev Rounds down: a budget never exceeds its wall-clock value at the
    /// modeled block time.
    function _blocks(uint64 secs, uint64 blockMilliseconds)
        private
        pure
        returns (Time.Duration)
    {
        require(blockMilliseconds != 0, BlockTimeCannotBeZero());
        return Time.Duration.wrap(secs * 1000 / blockMilliseconds);
    }
}
