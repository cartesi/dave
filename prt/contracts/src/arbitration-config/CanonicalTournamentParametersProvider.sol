// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ArbitrationConstants} from "./ArbitrationConstants.sol";
import {ClockBudgets} from "./ClockBudgets.sol";
import {ITournamentParametersProvider} from "./ITournamentParametersProvider.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {TournamentParameters} from "prt-contracts/types/TournamentParameters.sol";

contract CanonicalTournamentParametersProvider is
    ITournamentParametersProvider
{
    /// @notice The maximum allowance must span at least one block.
    error MaxAllowanceCannotBeZero();

    Time.Duration immutable RESPONSE_BUDGET;
    Time.Duration immutable COMMITMENT_BUDGET;
    Time.Duration immutable MAX_ALLOWANCE;

    /// @param blockMilliseconds The chain's modeled block time
    /// @param censorshipSeconds The censorship a correct commitment survives
    /// @param inclusionSeconds The time for one action to land
    /// @dev The commitment budget belongs to the geometry
    /// (ArbitrationConstants); the other inputs describe the deployment.
    constructor(
        uint64 blockMilliseconds,
        uint64 censorshipSeconds,
        uint64 inclusionSeconds
    ) {
        ClockBudgets.Model memory model =
            ClockBudgets.Model({
                blockMilliseconds: blockMilliseconds,
                censorshipSeconds: censorshipSeconds,
                inclusionSeconds: inclusionSeconds,
                commitmentSeconds: ArbitrationConstants.COMMITMENT_BUDGET
            });
        Time.Duration maxAllowance =
            ClockBudgets.maxAllowance(model, ArbitrationConstants.LEVELS);
        if (Time.Duration.unwrap(maxAllowance) == 0) {
            revert MaxAllowanceCannotBeZero();
        }

        RESPONSE_BUDGET = ClockBudgets.responseBudget(model);
        COMMITMENT_BUDGET = ClockBudgets.commitmentBudget(model);
        MAX_ALLOWANCE = maxAllowance;
    }

    /// @inheritdoc ITournamentParametersProvider
    function tournamentParameters(uint64 level)
        external
        view
        override
        returns (TournamentParameters memory)
    {
        return TournamentParameters({
            levels: ArbitrationConstants.LEVELS,
            log2step: ArbitrationConstants.log2step(level),
            height: ArbitrationConstants.height(level),
            responseBudget: RESPONSE_BUDGET,
            commitmentBudget: COMMITMENT_BUDGET,
            maxAllowance: MAX_ALLOWANCE
        });
    }
}
