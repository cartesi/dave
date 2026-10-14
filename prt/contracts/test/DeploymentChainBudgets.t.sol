// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {CanonicalTournamentParametersProvider} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {ITournamentParametersProvider} from "src/arbitration-config/ITournamentParametersProvider.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Machine} from "src/types/Machine.sol";
import {TournamentParameters} from "src/types/TournamentParameters.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {ProofSelectedStateTransition} from "test/fixtures/ProofSelectedStateTransition.sol";

import {ScriptProviderArguments} from "test/fixtures/ScriptProviderArguments.sol";

/// @dev Lead, not an exploit: modality "chain assumptions", questions 3
/// and 5.
///
/// Question 5: every registered chain's canonical rows, built from the
/// script's own constructor arguments, convert without rounding (12 s and
/// 2 s divide 5 min, 120 min, 8 h and 1 week), every level repeats the same
/// G and T, and `maxAllowance - blocks(C) - 2G` (the root join and the
/// in-flight reserve) is exactly one `T + 2G`, the sum winInnerTournament
/// refills. test/Deployment.t.sol pins only the 12 s rows; the 2 s OP Stack
/// rows are pinned here.
///
/// Question 3: clocks read `block.number` only. A deployed table keeps its
/// block counts across a slot-time fork, so halving Ethereum's slot to 6 s
/// (EIP-7782 style) halves every wall-clock budget of every deployed
/// factory: C from 7 days to 3.5, the root window from 7 d 2.33 h to
/// 3 d 13.2 h, T from 120 min to 60 (exactly the derivation budget in
/// docs/measurements/constants.md, so the doubled slack is gone), and G from
/// 300 s to 150 s (the slack-halved figure the per-input compute contract
/// in dimensioning.md already spends on replay alone). At 4 s, T would fall
/// to 40 min, below the 60-minute derivation, so the table would be invalid.
/// No contract-side guard exists, and DaveConsensus binds its factory
/// immutably, so existing applications cannot move to a new table.
contract DeploymentChainBudgetsTest is Test {
    struct Row {
        uint256 chainId;
        uint64 blockMs;
        uint64 censorship;
        uint64 g;
        uint64 t;
        uint64 maxAllowance;
    }

    function _deployProvider(uint256 chainId)
        internal
        returns (ITournamentParametersProvider provider)
    {
        vm.chainId(chainId);
        bytes memory code = abi.encodePacked(
            type(CanonicalTournamentParametersProvider).creationCode,
            new ScriptProviderArguments().providerArguments()
        );
        assembly ("memory-safe") {
            provider := create(0, add(code, 32), mload(code))
        }
        require(address(provider) != address(0), "provider deployment failed");
    }

    function _rows() internal pure returns (Row[10] memory r) {
        r[0] = Row(1, 12_000, 1 weeks, 25, 600, 51_100);
        r[1] = Row(10, 2_000, 1 weeks, 150, 3_600, 306_600);
        r[2] = Row(8453, 2_000, 1 weeks, 150, 3_600, 306_600);
        r[3] = Row(13370, 12_000, 0, 25, 600, 700);
        r[4] = Row(31337, 12_000, 0, 25, 600, 700);
        r[5] = Row(42161, 12_000, 1 weeks, 25, 600, 51_100);
        r[6] = Row(84532, 2_000, 8 hours, 150, 3_600, 18_600);
        r[7] = Row(421614, 12_000, 8 hours, 25, 600, 3_100);
        r[8] = Row(11155111, 12_000, 8 hours, 25, 600, 3_100);
        r[9] = Row(11155420, 2_000, 8 hours, 150, 3_600, 18_600);
    }

    function testTraceRegisteredRowsConvertExactly() public {
        Row[10] memory rows = _rows();
        for (uint256 i; i < rows.length; ++i) {
            Row memory e = rows[i];
            ITournamentParametersProvider provider = _deployProvider(e.chainId);
            for (uint64 level; level < ArbitrationConstants.LEVELS; ++level) {
                TournamentParameters memory p =
                    provider.tournamentParameters(level);
                uint64 g = Time.Duration.unwrap(p.responseBudget);
                uint64 t = Time.Duration.unwrap(p.commitmentBudget);
                uint64 a = Time.Duration.unwrap(p.maxAllowance);
                assertEq(g, e.g, "G");
                assertEq(t, e.t, "T");
                assertEq(a, e.maxAllowance, "maxAllowance");

                // No term was floored.
                assertEq(uint256(g) * e.blockMs, 5 minutes * 1000);
                assertEq(
                    uint256(t) * e.blockMs,
                    uint256(ArbitrationConstants.COMMITMENT_BUDGET) * 1000
                );
                uint64 refill = t + 2 * g;
                uint64 censorshipBlocks =
                    a - 2 * g - (ArbitrationConstants.LEVELS - 1) * refill;
                assertEq(
                    uint256(censorshipBlocks) * e.blockMs,
                    uint256(e.censorship) * 1000
                );
            }
        }
    }

    function testTraceSlotTimeHalvingHalvesEveryBudget() public {
        ITournamentParametersProvider provider = _deployProvider(1);
        MultiLevelTournamentFactory factory = new MultiLevelTournamentFactory(
            new InspectableTournament(),
            provider,
            new ProofSelectedStateTransition()
        );
        TournamentParameters memory p = factory.tournamentParameters(0);
        uint64 g = Time.Duration.unwrap(p.responseBudget);
        uint64 t = Time.Duration.unwrap(p.commitmentBudget);
        uint64 a = Time.Duration.unwrap(p.maxAllowance);
        uint64 c = a - 2 * g - (t + 2 * g);

        vm.roll(1_000);
        vm.warp(1_700_000_000);
        uint256 t0 = block.timestamp;
        ITournament root = factory.instantiate(
            Machine.Hash.wrap(bytes32(uint256(0xa))), IDataProvider(address(0))
        );

        // Wall time alone moves nothing: two weeks later, one block later,
        // the root still accepts joins.
        vm.warp(t0 + 2 weeks);
        vm.roll(block.number + 1);
        assertTrue(root.tournamentStanding().acceptsJoins);

        // At 6 s slots the window closes after the same block count, in half
        // the wall time it was dimensioned for.
        vm.roll(1_000 + uint256(a) - 1);
        assertTrue(root.tournamentStanding().acceptsJoins);
        vm.roll(1_000 + uint256(a));
        assertFalse(root.tournamentStanding().acceptsJoins);

        uint64 slot = 6;
        assertEq(uint256(c) * slot, 302_400, "C: 3.5 days");
        assertEq(uint256(a) * slot, 306_600, "root window: 3 d 13.2 h");
        assertEq(uint256(t) * slot, 60 minutes, "T: the derivation budget");
        assertEq(uint256(g) * slot, 150, "G: 150 s");
        assertLt(uint256(t) * 4, 60 minutes, "4 s slots: T below derivation");
    }
}
