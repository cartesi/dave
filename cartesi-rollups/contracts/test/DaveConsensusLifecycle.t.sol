// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {MachineValidationErrors} from "cartesi-rollups-contracts-3.0.0/src/common/MachineValidationErrors.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationChecker.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {RollupsTest} from "cartesi-rollups-contracts-3.0.0/test/util/RollupsTest.sol";

import {IDataProvider} from "prt-contracts/IDataProvider.sol";
import {ITournament} from "prt-contracts/ITournament.sol";
import {Machine} from "prt-contracts/types/Machine.sol";

import {IDaveConsensus} from "src/IDaveConsensus.sol";
import {ISentryErrors} from "src/ISentryErrors.sol";

import {
    DaveConsensusLifecycleHandler,
    DaveConsensusLifecycleVocabulary,
    Tally
} from "./DaveConsensusLifecycleHandler.sol";

/// @notice Deployment, the seeded walk and its evidence, shared by the
/// lifecycle suites.
/// @dev RollupsTest places the core contracts at their CREATE2 addresses, where
/// the handler then finds them.
abstract contract DaveConsensusLifecycleTestBase is RollupsTest, DaveConsensusLifecycleVocabulary {
    error WalkStepFailed(uint256 seed, uint256 step, bytes4 action, bytes reason);

    struct Kind {
        bytes4 action;
        bytes4 refusal;
        string label;
    }

    /// @dev Counts in the order of `Tally`, `_actions` and `_refusals`.
    struct Evidence {
        uint256[] tallies;
        uint256[] performed;
        uint256[] rejected;
    }

    bytes4 internal constant ADD_INPUT = IInputBox.addInput.selector;
    bytes4 internal constant STAGE = IDaveConsensus.stageTournamentResult.selector;
    bytes4 internal constant CLAIM = IDaveConsensus.submitSentryClaim.selector;
    bytes4 internal constant ACCEPT = IDaveConsensus.acceptStagedTournamentResult.selector;
    bytes4 internal constant ROTATE = IDaveConsensus.rotateSentry.selector;
    bytes4 internal constant PROVIDE = IDataProvider.provideMerkleRootOfInput.selector;
    bytes4 internal constant FORECLOSE = IApplication.foreclose.selector;
    bytes4 internal constant JOIN = ITournament.joinTournament.selector;
    bytes4 internal constant RESPOND = ITournament.advanceMatch.selector;
    bytes4 internal constant WIN_BY_TIMEOUT = ITournament.winMatchByTimeout.selector;
    bytes4 internal constant ELIMINATE = ITournament.eliminateMatchByTimeout.selector;
    bytes4 internal constant RECOVER = ITournament.tryRecoveringBond.selector;

    bytes4 internal constant FORECLOSED = IApplicationChecker.ApplicationForeclosed.selector;
    bytes4 internal constant WRONG_EPOCH = IDaveConsensus.IncorrectEpochNumber.selector;

    DaveConsensusLifecycleHandler internal handler;

    /// @notice Draw `depth` weighted actions from `seed`, checking the model
    /// after each.
    function _walk(uint256 seed, uint256 depth) internal {
        bytes4[] memory selectors = handler.weightedSelectors();
        for (uint256 step; step < depth; ++step) {
            uint256 draw = uint256(keccak256(abi.encode(seed, step)));
            bytes4 action = selectors[draw % selectors.length];
            // Each action reads as many seeds as it declares.
            bytes memory callData = abi.encodeWithSelector(
                action,
                uint256(keccak256(abi.encode(draw, uint256(1)))),
                uint256(keccak256(abi.encode(draw, uint256(2)))),
                uint256(keccak256(abi.encode(draw, uint256(3))))
            );
            (bool succeeded, bytes memory reason) = address(handler).call(callData);
            require(succeeded, WalkStepFailed(seed, step, action, reason));
            handler.assertModel();
        }
    }

    /// @notice One walk in its own call frame, so that a campaign's memory
    /// does not grow with its length.
    function runWalk(uint256 seed, uint256 depth) external returns (Evidence memory) {
        _walk(seed, depth);
        return _evidence();
    }

    /// @notice `walks` walks, each from the deployed state, seeded `seed`,
    /// `seed + 1` and so on: a failing walk replays alone under its own seed.
    function _campaign(uint256 seed, uint256 walks, uint256 depth) internal returns (Evidence memory total) {
        total = _evidence();
        uint256 deployed = vm.snapshotState();
        for (uint256 i; i < walks; ++i) {
            Evidence memory one = this.runWalk(seed + i, depth);
            _add(total.tallies, one.tallies);
            _add(total.performed, one.performed);
            _add(total.rejected, one.rejected);
            vm.revertToState(deployed);
        }
    }

    function _evidence() internal view returns (Evidence memory evidence) {
        evidence.tallies = handler.tallies();
        bytes4[] memory actions = _actions();
        evidence.performed = new uint256[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            evidence.performed[i] = handler.performed(actions[i]);
        }
        Kind[] memory refusals = _refusals();
        evidence.rejected = new uint256[](refusals.length);
        for (uint256 i; i < refusals.length; ++i) {
            evidence.rejected[i] = handler.rejected(refusals[i].action, refusals[i].refusal);
        }
    }

    function _add(uint256[] memory total, uint256[] memory part) private pure {
        for (uint256 i; i < total.length; ++i) {
            total[i] += part[i];
        }
    }

    function _log(Evidence memory evidence) internal {
        string[] memory names = _tallyNames();
        for (uint256 i; i < names.length; ++i) {
            emit log_named_uint(names[i], evidence.tallies[i]);
        }
        string[] memory actions = _actionNames();
        for (uint256 i; i < actions.length; ++i) {
            emit log_named_uint(string.concat("performed ", actions[i]), evidence.performed[i]);
        }
        Kind[] memory refusals = _refusals();
        for (uint256 i; i < refusals.length; ++i) {
            emit log_named_uint(string.concat("rejected ", refusals[i].label), evidence.rejected[i]);
        }
    }

    function _tallied(Evidence memory evidence, Tally kind) internal pure returns (uint256) {
        return evidence.tallies[uint256(kind)];
    }

    function _performed(Evidence memory evidence, bytes4 action) internal pure returns (uint256) {
        bytes4[] memory actions = _actions();
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i] == action) {
                return evidence.performed[i];
            }
        }
        revert("unlisted action");
    }

    function _rejected(Evidence memory evidence, bytes4 action, bytes4 refusal) internal pure returns (uint256) {
        Kind[] memory refusals = _refusals();
        for (uint256 i; i < refusals.length; ++i) {
            if (refusals[i].action == action && refusals[i].refusal == refusal) {
                return evidence.rejected[i];
            }
        }
        revert("unlisted refusal");
    }

    function _actions() internal pure returns (bytes4[] memory actions) {
        actions = new bytes4[](12);
        actions[0] = ADD_INPUT;
        actions[1] = STAGE;
        actions[2] = CLAIM;
        actions[3] = ACCEPT;
        actions[4] = ROTATE;
        actions[5] = FORECLOSE;
        actions[6] = PROVIDE;
        actions[7] = JOIN;
        actions[8] = RESPOND;
        actions[9] = WIN_BY_TIMEOUT;
        actions[10] = ELIMINATE;
        actions[11] = RECOVER;
    }

    function _actionNames() internal pure returns (string[] memory names) {
        names = new string[](12);
        names[0] = "addInput";
        names[1] = "stageTournamentResult";
        names[2] = "submitSentryClaim";
        names[3] = "acceptStagedTournamentResult";
        names[4] = "rotateSentry";
        names[5] = "foreclose";
        names[6] = "provideMerkleRootOfInput";
        names[7] = "joinTournament";
        names[8] = "advanceMatch";
        names[9] = "winMatchByTimeout";
        names[10] = "eliminateMatchByTimeout";
        names[11] = "tryRecoveringBond";
    }

    /// @notice Every refusal the model can name, by call and error.
    function _refusals() internal pure returns (Kind[] memory kinds) {
        kinds = new Kind[](39);
        uint256 next;
        kinds[next++] = _kind(STAGE, FORECLOSED, "stage: ApplicationForeclosed");
        kinds[next++] = _kind(STAGE, WRONG_EPOCH, "stage: IncorrectEpochNumber");
        kinds[next++] =
            _kind(STAGE, IDaveConsensus.TournamentResultAlreadyStaged.selector, "stage: TournamentResultAlreadyStaged");
        kinds[next++] =
            _kind(STAGE, IDaveConsensus.TournamentNotFinishedYet.selector, "stage: TournamentNotFinishedYet");
        kinds[next++] = _kind(STAGE, ITournament.TournamentFailedNoWinner.selector, "stage: TournamentFailedNoWinner");
        kinds[next++] = _kind(
            STAGE, MachineValidationErrors.InvalidSiblingsArrayLength.selector, "stage: InvalidSiblingsArrayLength"
        );
        kinds[next++] = _kind(
            STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector, "stage: InvalidMachineMerkleProof"
        );
        kinds[next++] = _kind(
            STAGE,
            MachineValidationErrors.InvalidPostEpochMachineIflagsYRegister.selector,
            "stage: InvalidPostEpochMachineIflagsYRegister"
        );
        kinds[next++] = _kind(
            STAGE,
            MachineValidationErrors.InvalidPostEpochMachineHtifTohostRegister.selector,
            "stage: InvalidPostEpochMachineHtifTohostRegister"
        );
        kinds[next++] = _kind(CLAIM, FORECLOSED, "claim: ApplicationForeclosed");
        kinds[next++] = _kind(CLAIM, IDaveConsensus.CallerIsNotSentry.selector, "claim: CallerIsNotSentry");
        kinds[next++] = _kind(CLAIM, WRONG_EPOCH, "claim: IncorrectEpochNumber");
        kinds[next++] = _kind(CLAIM, IDaveConsensus.SentryAlreadyClaimed.selector, "claim: SentryAlreadyClaimed");
        kinds[next++] = _kind(ACCEPT, FORECLOSED, "accept: ApplicationForeclosed");
        kinds[next++] = _kind(ACCEPT, WRONG_EPOCH, "accept: IncorrectEpochNumber");
        kinds[next++] =
            _kind(ACCEPT, IDaveConsensus.TournamentResultNotStaged.selector, "accept: TournamentResultNotStaged");
        kinds[next++] =
            _kind(ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector, "accept: ClaimStagingPeriodNotOverYet");
        kinds[next++] =
            _kind(ROTATE, IDaveConsensus.CallerIsNotSentryManager.selector, "rotate: CallerIsNotSentryManager");
        kinds[next++] = _kind(ROTATE, FORECLOSED, "rotate: ApplicationForeclosed");
        kinds[next++] = _kind(ROTATE, IDaveConsensus.CannotRotateNonSentry.selector, "rotate: CannotRotateNonSentry");
        kinds[next++] = _kind(ROTATE, ISentryErrors.ZeroSentryAddress.selector, "rotate: ZeroSentryAddress");
        kinds[next++] = _kind(ROTATE, ISentryErrors.DuplicatedSentryAddress.selector, "rotate: DuplicatedSentryAddress");
        kinds[next++] = _kind(ADD_INPUT, FORECLOSED, "addInput: ApplicationForeclosed");
        kinds[next++] = _kind(FORECLOSE, IApplication.NotGuardian.selector, "foreclose: NotGuardian");
        kinds[next++] = _kind(FORECLOSE, IApplication.Foreclosed.selector, "foreclose: Foreclosed");
        kinds[next++] = _kind(PROVIDE, IDaveConsensus.InputHashMismatch.selector, "provide: InputHashMismatch");
        kinds[next++] = _kind(JOIN, ITournament.TournamentIsClosed.selector, "join: TournamentIsClosed");
        kinds[next++] = _kind(RESPOND, ITournament.TournamentIsFinished.selector, "respond: TournamentIsFinished");
        kinds[next++] = _kind(RESPOND, ITournament.MatchDoesNotExist.selector, "respond: MatchDoesNotExist");
        kinds[next++] = _kind(RESPOND, ITournament.MatchCannotBeAdvanced.selector, "respond: MatchCannotBeAdvanced");
        kinds[next++] =
            _kind(RESPOND, ITournament.CannotAdvanceTimedOutClock.selector, "respond: CannotAdvanceTimedOutClock");
        kinds[next++] =
            _kind(WIN_BY_TIMEOUT, ITournament.TournamentIsFinished.selector, "winByTimeout: TournamentIsFinished");
        kinds[next++] = _kind(WIN_BY_TIMEOUT, ITournament.MatchDoesNotExist.selector, "winByTimeout: MatchDoesNotExist");
        kinds[next++] = _kind(
            WIN_BY_TIMEOUT, ITournament.MatchCannotBeWonByTimeout.selector, "winByTimeout: MatchCannotBeWonByTimeout"
        );
        kinds[next++] = _kind(ELIMINATE, ITournament.TournamentIsFinished.selector, "eliminate: TournamentIsFinished");
        kinds[next++] = _kind(ELIMINATE, ITournament.MatchDoesNotExist.selector, "eliminate: MatchDoesNotExist");
        kinds[next++] = _kind(
            ELIMINATE,
            ITournament.MatchCannotBeEliminatedByTimeout.selector,
            "eliminate: MatchCannotBeEliminatedByTimeout"
        );
        kinds[next++] = _kind(RECOVER, ITournament.TournamentNotFinished.selector, "recover: TournamentNotFinished");
        kinds[next++] = _kind(RECOVER, ITournament.NoWinner.selector, "recover: NoWinner");
        assert(next == kinds.length);
    }

    function _kind(bytes4 action, bytes4 refusal, string memory label) private pure returns (Kind memory) {
        return Kind({action: action, refusal: refusal, label: label});
    }

    function _tallyNames() internal pure returns (string[] memory names) {
        names = new string[](uint256(type(Tally).max) + 1);
        names[uint256(Tally.BACKLOGS)] = "backlogs added";
        names[uint256(Tally.JOINS_BEYOND_THE_MODEL)] = "joins beyond the model (skipped)";
        names[uint256(Tally.ROOTS_WON_UNCONTESTED)] = "roots won uncontested";
        names[uint256(Tally.ROOTS_WON_BY_FIRST_ENTRANT)] = "roots won by the first entrant";
        names[uint256(Tally.ROOTS_WON_BY_SECOND_ENTRANT)] = "roots won by the second entrant";
        names[uint256(Tally.ROOTS_LEFT_EMPTY)] = "roots left empty";
        names[uint256(Tally.ROOTS_LOST_TO_DOUBLE_ELIMINATION)] = "roots lost to double elimination";
        names[uint256(Tally.EPOCHS_STAGED)] = "epochs staged";
        names[uint256(Tally.EPOCHS_ACCEPTED_BY_AGREEMENT)] = "epochs accepted by agreement";
        names[uint256(Tally.EPOCHS_ACCEPTED_BY_PERIOD)] = "epochs accepted by period";
        names[uint256(Tally.EPOCHS_ACCEPTED_WITH_BOTH)] = "epochs accepted with both";
        names[uint256(Tally.ACCEPTANCES_UNDER_A_REPLACED_REPORT)] = "acceptances under a replaced report";
        names[uint256(Tally.AGREEING_CLAIMS_AT_ACCEPTANCE)] = "agreeing claims at acceptance";
        names[uint256(Tally.DISSENTING_CLAIMS_AT_ACCEPTANCE)] = "dissenting claims at acceptance";
        names[uint256(Tally.ROTATIONS)] = "rotations";
        names[uint256(Tally.ROTATIONS_OF_A_CLAIMED_SLOT)] = "rotations of a claimed slot";
        names[uint256(Tally.FORECLOSURES)] = "foreclosures";
        names[uint256(Tally.BONDS_RECOVERED)] = "bonds recovered";
        names[uint256(Tally.BONDS_RECOVERED_WHILE_STAGED)] = "bonds recovered while staged";
        names[uint256(Tally.BONDS_RECOVERED_FROM_A_RETIRED_ROOT)] = "bonds recovered from a retired root";
        names[uint256(Tally.REPEATED_RECOVERIES)] = "repeated recoveries";
        names[uint256(Tally.EPOCHS_SEALED_AT_CAPACITY)] = "epochs sealed at capacity";
        names[uint256(Tally.EPOCHS_SEALED_WITH_INPUTS_PENDING)] = "epochs sealed with inputs pending";
        names[uint256(Tally.INPUTS_BOUND)] = "inputs bound";
        names[uint256(Tally.INPUTS_PADDED)] = "inputs padded";
        names[uint256(Tally.INPUTS_MISMATCHED)] = "inputs mismatched";
    }
}

/// @notice The settlement properties under forge's invariant engine, three
/// sentries and a six-block claim staging period.
///
/// After every handler call the model must still describe the consensus:
/// settled values come only from the staged snapshot of a root winner whose
/// state the proof opened; the epoch number, bounds, capacity and input
/// finality follow one acceptance at a time; acceptance needs a staged result
/// and either every slot's vote for it or the elapsed period; a slot votes
/// once per epoch and keeps its vote through a rotation; one tournament
/// serves one epoch and starts from the settled state; consensus calls move
/// no tournament value; a foreclosed application refuses all four mutators and
/// its stored views stop moving; and inputs bind their bytes inside the sealed
/// span and pad with zero beyond it.
///
/// A handler revert fails the run: the handler turns every call the model
/// forbids into an exact-error check, so only a broken expectation reverts.
/// What this does not establish is listed on the handler.
contract DaveConsensusLifecycleInvariantTest is DaveConsensusLifecycleTestBase {
    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(3, 6);
        targetSelector(FuzzSelector({addr: address(handler), selectors: handler.weightedSelectors()}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 160
    function invariantSettlementFollowsTheModel() public view {
        handler.assertModel();
    }
}

/// @notice The same properties with no sentries, where only the period path
/// can accept, and a four-block period.
contract DaveConsensusLifecycleNoSentriesInvariantTest is DaveConsensusLifecycleTestBase {
    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(0, 4);
        targetSelector(FuzzSelector({addr: address(handler), selectors: handler.weightedSelectors()}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 160
    function invariantSettlementFollowsTheModelWithoutSentries() public view {
        handler.assertModel();
    }
}

/// @notice Seeded walks over the handler's weighted actions: the evidence
/// that the invariant campaigns' operations run, and the deeper campaign.
///
/// The walks draw from the same selector weights as the invariant campaigns
/// and check the model after every step, but from a fixed seed, so the counts
/// they reach are reproducible and can be required.
///
/// `testFuzzSeededWalk` is the same walk with one fuzz run being one walk
/// from the deployed state, one in sixteen of them long. For a deeper
/// campaign raise its budget and record the seed:
///
///   FOUNDRY_FUZZ_RUNS=4000 FOUNDRY_FUZZ_SEED=<seed> forge test \
///     --match-test testFuzzSeededWalk
///
/// The two invariant tests cannot be deepened this way: their inline settings
/// take precedence over the environment, so raise the numbers there instead.
abstract contract DaveConsensusLifecycleWalkTest is DaveConsensusLifecycleTestBase {
    uint256 internal constant WALKS = 16;
    uint256 internal constant DEPTH = 120;
    uint256 internal constant SEED = 0x5eed;

    uint256 internal constant FUZZ_DEPTH = 32;
    uint256 internal constant LONG_FUZZ_DEPTH = 256;

    function _requireEvidence(Evidence memory total) internal virtual;

    function testSeededWalksReachEveryOperation() public {
        Evidence memory total = _campaign(SEED, WALKS, DEPTH);
        _log(total);
        _requireEvidence(total);
    }

    function testFuzzSeededWalk(uint256 seed) public {
        bool isLong = uint256(keccak256(abi.encode(seed, "depth"))) % 16 == 0;
        _walk(seed, isLong ? LONG_FUZZ_DEPTH : FUZZ_DEPTH);
    }

    /// @notice What every configuration must reach, at about half of what
    /// the default seed reaches.
    function _requireSettlementEvidence(Evidence memory total) internal pure {
        assertGe(_tallied(total, Tally.ROOTS_WON_UNCONTESTED), 10, "uncontested roots");
        assertGe(_tallied(total, Tally.ROOTS_WON_BY_FIRST_ENTRANT), 3, "first entrant winners");
        assertGe(_tallied(total, Tally.ROOTS_WON_BY_SECOND_ENTRANT), 1, "second entrant winners");
        assertGe(_tallied(total, Tally.ROOTS_LEFT_EMPTY), 1, "empty roots");
        assertGe(_tallied(total, Tally.ROOTS_LOST_TO_DOUBLE_ELIMINATION), 1, "double eliminations");
        assertGe(_tallied(total, Tally.EPOCHS_STAGED), 12, "epochs staged");
        assertGe(_tallied(total, Tally.ACCEPTANCES_UNDER_A_REPLACED_REPORT), 8, "accepted under a replaced report");
        assertGe(_tallied(total, Tally.FORECLOSURES), 2, "foreclosures");
        assertGe(_tallied(total, Tally.BONDS_RECOVERED_WHILE_STAGED), 2, "recoveries while staged");
        assertGe(_tallied(total, Tally.BONDS_RECOVERED_FROM_A_RETIRED_ROOT), 2, "recoveries from retired roots");
        assertGe(_tallied(total, Tally.REPEATED_RECOVERIES), 30, "repeated recoveries");
        assertGe(_tallied(total, Tally.BACKLOGS), 2, "backlogs");
        assertGe(_tallied(total, Tally.EPOCHS_SEALED_AT_CAPACITY), 1, "spans at capacity");
        assertGe(_tallied(total, Tally.EPOCHS_SEALED_WITH_INPUTS_PENDING), 1, "spans leaving inputs pending");
        assertGe(_tallied(total, Tally.INPUTS_BOUND), 4, "inputs bound");
        assertGe(_tallied(total, Tally.INPUTS_PADDED), 20, "inputs padded");
        assertGe(_tallied(total, Tally.INPUTS_MISMATCHED), 6, "inputs mismatched");
        assertGe(_performed(total, ADD_INPUT), 50, "inputs added");

        assertGe(_rejected(total, STAGE, FORECLOSED), 5, "staging after foreclosure");
        assertGe(_rejected(total, STAGE, WRONG_EPOCH), 15, "staging a wrong epoch");
        assertGe(_rejected(total, STAGE, IDaveConsensus.TournamentResultAlreadyStaged.selector), 20, "staging twice");
        assertGe(_rejected(total, STAGE, IDaveConsensus.TournamentNotFinishedYet.selector), 20, "staging too early");
        assertGe(_rejected(total, STAGE, ITournament.TournamentFailedNoWinner.selector), 3, "staging a failed root");
        assertGe(
            _rejected(total, STAGE, MachineValidationErrors.InvalidSiblingsArrayLength.selector),
            1,
            "staging a malformed proof"
        );
        assertGe(
            _rejected(total, STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector),
            6,
            "staging an unbound proof"
        );
        assertGe(
            _rejected(total, STAGE, MachineValidationErrors.InvalidPostEpochMachineIflagsYRegister.selector),
            4,
            "staging a state with iflags.Y unset"
        );
        assertGe(
            _rejected(total, STAGE, MachineValidationErrors.InvalidPostEpochMachineHtifTohostRegister.selector),
            1,
            "staging a state that did not accept its input"
        );
        assertGe(_rejected(total, CLAIM, FORECLOSED), 5, "claims after foreclosure");
        assertGe(_rejected(total, CLAIM, IDaveConsensus.CallerIsNotSentry.selector), 20, "claims by non-sentries");
        assertGe(_rejected(total, ACCEPT, FORECLOSED), 4, "acceptance after foreclosure");
        assertGe(_rejected(total, ACCEPT, WRONG_EPOCH), 10, "accepting a wrong epoch");
        assertGe(_rejected(total, ACCEPT, IDaveConsensus.TournamentResultNotStaged.selector), 40, "accepting unstaged");
        assertGe(
            _rejected(total, ROTATE, IDaveConsensus.CallerIsNotSentryManager.selector), 4, "rotations by non-managers"
        );
        assertGe(_rejected(total, ROTATE, FORECLOSED), 4, "rotations after foreclosure");
        assertGe(_rejected(total, ADD_INPUT, FORECLOSED), 4, "inputs after foreclosure");
        assertGe(_rejected(total, FORECLOSE, IApplication.NotGuardian.selector), 20, "foreclosure by non-guardians");
        assertGe(_rejected(total, FORECLOSE, IApplication.Foreclosed.selector), 1, "second foreclosures");
        assertGe(_rejected(total, RECOVER, ITournament.TournamentNotFinished.selector), 6, "recovery of a live root");
        assertGe(_rejected(total, RECOVER, ITournament.NoWinner.selector), 3, "recovery without a winner");
    }
}

contract DaveConsensusLifecycleThreeSentriesWalkTest is DaveConsensusLifecycleWalkTest {
    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(3, 6);
    }

    function _requireEvidence(Evidence memory total) internal pure override {
        _requireSettlementEvidence(total);
        assertGe(_tallied(total, Tally.EPOCHS_ACCEPTED_BY_AGREEMENT), 3, "accepted by agreement");
        assertGe(_tallied(total, Tally.EPOCHS_ACCEPTED_BY_PERIOD), 5, "accepted by period");
        assertGe(_tallied(total, Tally.EPOCHS_ACCEPTED_WITH_BOTH), 2, "accepted with both");
        assertGe(_tallied(total, Tally.AGREEING_CLAIMS_AT_ACCEPTANCE), 25, "agreeing claims");
        assertGe(_tallied(total, Tally.DISSENTING_CLAIMS_AT_ACCEPTANCE), 4, "dissenting claims");
        assertGe(_tallied(total, Tally.ROTATIONS), 30, "rotations");
        assertGe(_tallied(total, Tally.ROTATIONS_OF_A_CLAIMED_SLOT), 15, "rotations of a claimed slot");
        assertGe(_rejected(total, ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector), 1, "early acceptance");
        assertGe(_rejected(total, CLAIM, WRONG_EPOCH), 10, "claims for a wrong epoch");
        assertGe(_rejected(total, CLAIM, IDaveConsensus.SentryAlreadyClaimed.selector), 25, "second claims");
        assertGe(_rejected(total, ROTATE, IDaveConsensus.CannotRotateNonSentry.selector), 3, "rotating a non-sentry");
        assertGe(_rejected(total, ROTATE, ISentryErrors.ZeroSentryAddress.selector), 1, "rotating to zero");
        assertGe(_rejected(total, ROTATE, ISentryErrors.DuplicatedSentryAddress.selector), 3, "rotating to a sentry");
    }
}

contract DaveConsensusLifecycleNoSentriesWalkTest is DaveConsensusLifecycleWalkTest {
    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(0, 4);
    }

    function _requireEvidence(Evidence memory total) internal pure override {
        _requireSettlementEvidence(total);
        // Without sentries nothing is ever accepted ahead of the period.
        assertEq(_tallied(total, Tally.EPOCHS_ACCEPTED_BY_AGREEMENT), 0, "accepted by agreement");
        assertEq(_tallied(total, Tally.EPOCHS_ACCEPTED_WITH_BOTH), 0, "accepted with both");
        assertGe(_tallied(total, Tally.EPOCHS_ACCEPTED_BY_PERIOD), 10, "accepted by period");
        assertEq(_performed(total, CLAIM), 0, "claims");
        assertEq(_performed(total, ROTATE), 0, "rotations");
        assertGe(_rejected(total, ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector), 3, "early acceptance");
        assertGe(_rejected(total, ROTATE, IDaveConsensus.CannotRotateNonSentry.selector), 40, "rotating a non-sentry");
    }
}

/// @notice One sentry and a zero period: a staged result is acceptable in
/// its own block, so a vote can only ever coincide with an elapsed period.
contract DaveConsensusLifecycleZeroPeriodWalkTest is DaveConsensusLifecycleWalkTest {
    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(1, 0);
    }

    function _requireEvidence(Evidence memory total) internal pure override {
        _requireSettlementEvidence(total);
        assertEq(_tallied(total, Tally.EPOCHS_ACCEPTED_BY_AGREEMENT), 0, "accepted by agreement");
        assertGe(_tallied(total, Tally.EPOCHS_ACCEPTED_BY_PERIOD), 4, "accepted by period");
        assertGe(_tallied(total, Tally.EPOCHS_ACCEPTED_WITH_BOTH), 8, "accepted with both");
        assertEq(_rejected(total, ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector), 0, "early acceptance");
    }
}

/// @notice Directed schedules through the handler: each names the outcome it
/// expects, call by call, and the model is compared after every call. They
/// fix the schedules the walks reach by chance.
contract DaveConsensusLifecycleScheduleTest is DaveConsensusLifecycleTestBase {
    uint256 internal constant PERIOD = 6;

    IDaveConsensus internal consensus;
    address internal app;

    mapping(bytes4 => uint256) private _expectedPerformed;
    mapping(bytes4 => mapping(bytes4 => uint256)) private _expectedRejected;

    function setUp() public {
        handler = new DaveConsensusLifecycleHandler(3, PERIOD);
        consensus = handler.consensus();
        app = address(handler.app());
    }

    function testUncontestedEntrantWinsAtClosureAndItsStateSettles() public {
        handler.joinRootWith(SETTLING_TWO);
        _succeeded(JOIN);

        handler.elapseBy(ROOT_ALLOWANCE - 1);
        handler.stageAs(BYSTANDER, 0, SETTLING_TWO, INTACT);
        _refused(STAGE, IDaveConsensus.TournamentNotFinishedYet.selector);

        handler.elapseBy(1);
        handler.stageAs(BYSTANDER, 0, SETTLING_TWO, INTACT);
        _succeeded(STAGE);

        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _refused(ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector);
        handler.elapseBy(PERIOD - 1);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _refused(ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector);
        handler.elapseBy(1);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);

        assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), handler.stateOf(SETTLING_TWO));
        assertTrue(consensus.isOutputsMerkleRootValid(app, handler.outputsRootOf(SETTLING_TWO)));
        assertFalse(consensus.isOutputsMerkleRootValid(app, handler.outputsRootOf(SETTLING_ONE)));
        assertEq(handler.tally(Tally.ROOTS_WON_UNCONTESTED), 1);
        assertEq(handler.tally(Tally.EPOCHS_ACCEPTED_BY_PERIOD), 1);
    }

    function testEmptyRootHoldsTheEpochUntilForeclosure() public {
        handler.elapseBy(ROOT_ALLOWANCE);
        (bool isFinished, bool isFailed,,,,) = consensus.canStageTournamentResult();
        assertTrue(isFinished);
        assertTrue(isFailed);
        assertEq(handler.tally(Tally.ROOTS_LEFT_EMPTY), 1);

        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, ITournament.TournamentFailedNoWinner.selector);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _refused(ACCEPT, IDaveConsensus.TournamentResultNotStaged.selector);
        handler.recoverBondOf(0, BYSTANDER);
        _refused(RECOVER, ITournament.NoWinner.selector);
        handler.joinRootWith(SETTLING_ONE);
        _refused(JOIN, ITournament.TournamentIsClosed.selector);

        // No amount of waiting helps; the guardian's switch is what is left.
        handler.elapseBy(1000);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, ITournament.TournamentFailedNoWinner.selector);
        handler.forecloseAs(GUARDIAN);
        _succeeded(FORECLOSE);
        (uint256 epochNumber,,,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 0);
    }

    function testTimedOutFirstEntrantLeavesTheSecondAsWinner() public {
        handler.joinRootWith(UNPROVABLE);
        _succeeded(JOIN);
        handler.elapseBy(2);
        handler.joinRootWith(SETTLING_ONE);
        _succeeded(JOIN);

        // The match outlives the joining window: closed is not finished.
        handler.elapseBy(ROOT_ALLOWANCE - 2);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, IDaveConsensus.TournamentNotFinishedYet.selector);
        handler.claimTimeoutWith(false);
        _refused(WIN_BY_TIMEOUT, ITournament.MatchCannotBeWonByTimeout.selector);

        // The first entrant's clock started at the pairing with its full
        // allowance, and it never responds.
        handler.elapseBy(2);
        handler.claimTimeoutWith(false);
        _succeeded(WIN_BY_TIMEOUT);
        assertEq(handler.tally(Tally.ROOTS_WON_BY_SECOND_ENTRANT), 1);

        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);
        handler.elapseBy(PERIOD);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);
        assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), handler.stateOf(SETTLING_ONE));
    }

    function testRespondingFirstEntrantOutlastsASilentSecond() public {
        handler.joinRootWith(SETTLING_ONE);
        _succeeded(JOIN);
        handler.elapseBy(1);
        handler.joinRootWith(SETTLING_TWO);
        _succeeded(JOIN);

        // Three blocks to respond, one beyond the response budget.
        handler.elapseBy(3);
        handler.respondInMatch();
        _succeeded(RESPOND);
        handler.respondInMatch();
        _refused(RESPOND, ITournament.MatchCannotBeAdvanced.selector);

        // The second entrant joined one block late, so it has fifteen.
        handler.elapseBy(14);
        handler.claimTimeoutWith(false);
        _refused(WIN_BY_TIMEOUT, ITournament.MatchCannotBeWonByTimeout.selector);
        handler.elapseBy(1);
        handler.claimTimeoutWith(false);
        _succeeded(WIN_BY_TIMEOUT);
        assertEq(handler.tally(Tally.ROOTS_WON_BY_FIRST_ENTRANT), 1);

        handler.stageAs(BYSTANDER, 0, SETTLING_TWO, INTACT);
        _refused(STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);
        handler.elapseBy(PERIOD);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);
        assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), handler.stateOf(SETTLING_ONE));
    }

    function testDoubleEliminationLeavesNoWinnerToStage() public {
        handler.joinRootWith(SETTLING_ONE);
        _succeeded(JOIN);
        handler.joinRootWith(SETTLING_TWO);
        _succeeded(JOIN);

        // One block short of the second allowance the second entrant could
        // still claim the win.
        handler.elapseBy(2 * ROOT_ALLOWANCE - 1);
        handler.claimTimeoutWith(true);
        _refused(ELIMINATE, ITournament.MatchCannotBeEliminatedByTimeout.selector);
        handler.elapseBy(1);
        handler.claimTimeoutWith(false);
        _refused(WIN_BY_TIMEOUT, ITournament.MatchCannotBeWonByTimeout.selector);
        handler.claimTimeoutWith(true);
        _succeeded(ELIMINATE);
        assertEq(handler.tally(Tally.ROOTS_LOST_TO_DOUBLE_ELIMINATION), 1);

        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, ITournament.TournamentFailedNoWinner.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_TWO, INTACT);
        _refused(STAGE, ITournament.TournamentFailedNoWinner.selector);
    }

    function testUnanimousSentriesSettleInTheStagingBlock() public {
        bytes32 state = handler.stateOf(SETTLING_ONE);

        // A vote may precede the result it turns out to agree with.
        handler.claimAs(handler.sentryAt(1), 0, state);
        _succeeded(CLAIM);
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);
        handler.claimAs(handler.sentryAt(2), 0, state);
        _succeeded(CLAIM);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);

        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _refused(ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector);
        handler.claimAs(handler.sentryAt(3), 0, state);
        _succeeded(CLAIM);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);
        assertEq(handler.tally(Tally.EPOCHS_ACCEPTED_BY_AGREEMENT), 1);

        // Votes belong to their epoch.
        assertEq(consensus.getSentryClaimCount(0, Machine.Hash.wrap(state)), 3);
        assertEq(consensus.getSentryClaimCount(1, Machine.Hash.wrap(state)), 0);
    }

    function testOneDissentingSentryKeepsTheStagingPeriod() public {
        bytes32 state = handler.stateOf(SETTLING_ONE);
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);

        handler.claimAs(handler.sentryAt(1), 0, state);
        _succeeded(CLAIM);
        handler.claimAs(handler.sentryAt(2), 0, state);
        _succeeded(CLAIM);
        handler.claimAs(handler.sentryAt(3), 0, handler.stateOf(SETTLING_TWO));
        _succeeded(CLAIM);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _refused(ACCEPT, IDaveConsensus.ClaimStagingPeriodNotOverYet.selector);

        // The dissent cannot be taken back, and it cannot hold the epoch.
        handler.claimAs(handler.sentryAt(3), 0, state);
        _refused(CLAIM, IDaveConsensus.SentryAlreadyClaimed.selector);
        handler.elapseBy(PERIOD);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);

        assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), state);
        assertFalse(consensus.isOutputsMerkleRootValid(app, handler.outputsRootOf(SETTLING_TWO)));
        assertEq(handler.tally(Tally.EPOCHS_ACCEPTED_BY_PERIOD), 1);
        assertEq(handler.tally(Tally.AGREEING_CLAIMS_AT_ACCEPTANCE), 2);
        assertEq(handler.tally(Tally.DISSENTING_CLAIMS_AT_ACCEPTANCE), 1);
    }

    function testRotatedSlotKeepsItsClaimAndItsVote() public {
        bytes32 state = handler.stateOf(SETTLING_ONE);
        address first = handler.sentryAt(1);
        address successor = handler.spareSentry(0);
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);

        handler.claimAs(first, 0, state);
        _succeeded(CLAIM);
        handler.rotateAs(MANAGER, first, successor);
        _succeeded(ROTATE);
        assertEq(handler.tally(Tally.ROTATIONS_OF_A_CLAIMED_SLOT), 1);

        // The slot has voted: neither holder can vote for it again.
        handler.claimAs(successor, 0, state);
        _refused(CLAIM, IDaveConsensus.SentryAlreadyClaimed.selector);
        handler.claimAs(first, 0, state);
        _refused(CLAIM, IDaveConsensus.CallerIsNotSentry.selector);

        handler.claimAs(handler.sentryAt(2), 0, state);
        _succeeded(CLAIM);
        handler.claimAs(handler.sentryAt(3), 0, state);
        _succeeded(CLAIM);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);
        assertEq(handler.tally(Tally.EPOCHS_ACCEPTED_BY_AGREEMENT), 1);

        // The successor votes from the next epoch on.
        handler.claimAs(successor, 1, state);
        _succeeded(CLAIM);
    }

    function testAcceptanceSettlesTheSnapshotWhateverTheTournamentReports() public {
        uint8[3] memory reports = [REPORT_ANOTHER_WINNER, REPORT_FAILED_ROOT, REPORT_REVERTS];
        for (uint256 i; i < reports.length; ++i) {
            uint8 machine = i % 2 == 0 ? SETTLING_ONE : SETTLING_TWO;
            handler.joinRootWith(machine);
            handler.elapseBy(ROOT_ALLOWANCE);
            handler.stageAs(BYSTANDER, i, machine, INTACT);
            _succeeded(STAGE);
            handler.elapseBy(PERIOD);
            handler.acceptAs(BYSTANDER, i, reports[i]);
            _succeeded(ACCEPT);
            assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), handler.stateOf(machine));
        }
        assertEq(handler.tally(Tally.ACCEPTANCES_UNDER_A_REPLACED_REPORT), 3);
    }

    function testNoTournamentCallBetweenStagingAndAcceptanceMovesTheSnapshot() public {
        handler.joinRootWith(SETTLING_ONE);
        _succeeded(JOIN);
        handler.elapseBy(ROOT_ALLOWANCE);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);
        bytes32 snapshot = _stagedSnapshot();

        handler.recoverBondOf(0, BYSTANDER);
        _succeeded(RECOVER);
        assertEq(handler.tally(Tally.BONDS_RECOVERED_WHILE_STAGED), 1);
        handler.recoverBondOf(0, BYSTANDER);
        _succeeded(RECOVER);
        assertEq(handler.tally(Tally.REPEATED_RECOVERIES), 1);
        handler.joinRootWith(SETTLING_TWO);
        _refused(JOIN, ITournament.TournamentIsClosed.selector);
        handler.respondInMatch();
        _refused(RESPOND, ITournament.TournamentIsFinished.selector);
        handler.claimTimeoutWith(false);
        _refused(WIN_BY_TIMEOUT, ITournament.TournamentIsFinished.selector);
        handler.claimTimeoutWith(true);
        _refused(ELIMINATE, ITournament.TournamentIsFinished.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, IDaveConsensus.TournamentResultAlreadyStaged.selector);
        assertEq(_stagedSnapshot(), snapshot);

        handler.elapseBy(PERIOD);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);
        assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), handler.stateOf(SETTLING_ONE));
    }

    function testBacklogSealsOneCapacitySpanPerEpoch() public {
        handler.addInputFrom(BYSTANDER, "first");
        handler.addInputFrom(BYSTANDER, "second");
        handler.addInputBacklog(EPOCH_INPUT_CAPACITY + 1);

        handler.settleEpochWith(SETTLING_ONE);
        handler.assertModel();
        (uint256 epochNumber, uint256 lower, uint256 upper,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 1);
        assertEq(lower, 0);
        assertEq(upper, EPOCH_INPUT_CAPACITY);
        assertFalse(consensus.wasInputFinalized(app, 0, 0));
        assertEq(handler.tally(Tally.EPOCHS_SEALED_AT_CAPACITY), 1);
        assertEq(handler.tally(Tally.EPOCHS_SEALED_WITH_INPUTS_PENDING), 1);

        // A sealed input binds its bytes; a backlog entry has none to offer.
        handler.probeInputWith(1, handler.inputAt(1));
        assertEq(handler.tally(Tally.INPUTS_BOUND), 1);
        handler.probeInputWith(2, "no such bytes");
        _refused(PROVIDE, IDaveConsensus.InputHashMismatch.selector);
        handler.probeInputWith(EPOCH_INPUT_CAPACITY, handler.inputAt(0));
        assertEq(handler.tally(Tally.INPUTS_PADDED), 1);

        // The three inputs left pending make the next epoch.
        handler.settleEpochWith(SETTLING_TWO);
        handler.assertModel();
        (epochNumber, lower, upper,,,,,) = consensus.getCurrentSealedEpoch();
        assertEq(epochNumber, 2);
        assertEq(lower, EPOCH_INPUT_CAPACITY);
        assertEq(upper, EPOCH_INPUT_CAPACITY + 3);
        assertTrue(consensus.wasInputFinalized(app, EPOCH_INPUT_CAPACITY - 1, 0));
        assertFalse(consensus.wasInputFinalized(app, EPOCH_INPUT_CAPACITY, 0));
    }

    function testForeclosureFreezesSettlementWhileReadinessFollowsTheClock() public {
        bytes32 state = handler.stateOf(SETTLING_ONE);
        handler.addInputFrom(BYSTANDER, "pending");
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);
        handler.claimAs(handler.sentryAt(1), 0, state);
        _succeeded(CLAIM);

        handler.forecloseAs(BYSTANDER);
        _refused(FORECLOSE, IApplication.NotGuardian.selector);
        handler.forecloseAs(GUARDIAN);
        _succeeded(FORECLOSE);
        handler.forecloseAs(GUARDIAN);
        _refused(FORECLOSE, IApplication.Foreclosed.selector);

        // The readiness view keeps counting blocks...
        (,, bool periodOver,,,) = consensus.canAcceptStagedTournamentResult();
        assertFalse(periodOver);
        handler.elapseBy(PERIOD);
        (,, periodOver,,,) = consensus.canAcceptStagedTournamentResult();
        assertTrue(periodOver);

        // ...while the call it advertises, and every other mutator, refuses.
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _refused(ACCEPT, FORECLOSED);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, FORECLOSED);
        handler.claimAs(handler.sentryAt(2), 0, state);
        _refused(CLAIM, FORECLOSED);
        handler.rotateAs(MANAGER, handler.sentryAt(3), handler.spareSentry(0));
        _refused(ROTATE, FORECLOSED);
        handler.addInputFrom(BYSTANDER, "late");
        _refused(ADD_INPUT, FORECLOSED);

        // The staged result never settled, and its inputs never finalized.
        assertEq(consensus.getLastFinalizedMachineMerkleRoot(app), bytes32(0));
        assertFalse(consensus.isOutputsMerkleRootValid(app, handler.outputsRootOf(SETTLING_ONE)));
        assertFalse(consensus.wasInputFinalized(app, 0, 0));

        // The retired dispute still pays its winner.
        handler.recoverBondOf(0, BYSTANDER);
        _succeeded(RECOVER);
    }

    function testForeclosedEpochStillReportsItsRootResult() public {
        handler.joinRootWith(SETTLING_ONE);
        handler.forecloseAs(GUARDIAN);
        _succeeded(FORECLOSE);
        (bool isFinished,,,,,) = consensus.canStageTournamentResult();
        assertFalse(isFinished);

        handler.elapseBy(ROOT_ALLOWANCE);
        Machine.Hash winnerState;
        (isFinished,,,,, winnerState) = consensus.canStageTournamentResult();
        assertTrue(isFinished);
        assertEq(Machine.Hash.unwrap(winnerState), handler.stateOf(SETTLING_ONE));
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _refused(STAGE, FORECLOSED);
    }

    function testWinnerThatDoesNotSettleHoldsTheEpoch() public {
        uint8[3] memory winners = [UNSET_IFLAGS_Y, NOT_ACCEPTED, UNPROVABLE];
        bytes4[3] memory verdicts = [
            MachineValidationErrors.InvalidPostEpochMachineIflagsYRegister.selector,
            MachineValidationErrors.InvalidPostEpochMachineHtifTohostRegister.selector,
            MachineValidationErrors.InvalidMachineMerkleProof.selector
        ];
        uint256 deployed = vm.snapshotState();
        for (uint256 i; i < winners.length; ++i) {
            handler.joinRootWith(winners[i]);
            handler.elapseBy(ROOT_ALLOWANCE);
            (bool isFinished, bool isFailed,,,,) = consensus.canStageTournamentResult();
            assertTrue(isFinished);
            assertFalse(isFailed);

            // Its own proof where the state has one, a settling proof otherwise.
            handler.stageAs(BYSTANDER, 0, winners[i] == UNPROVABLE ? SETTLING_ONE : winners[i], INTACT);
            assertEq(handler.rejected(STAGE, verdicts[i]), 1);
            handler.stageAs(BYSTANDER, 0, SETTLING_TWO, INTACT);
            assertEq(
                handler.rejected(STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector), i == 2 ? 2 : 1
            );
            assertEq(handler.performed(STAGE), 0);
            handler.assertModel();
            vm.revertToState(deployed);
        }
    }

    function testStagingRejectsEveryAlteredProofOfTheWinner() public {
        handler.joinRootWith(SETTLING_ONE);
        handler.elapseBy(ROOT_ALLOWANCE);

        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, SHORT_IFLAGS_SIBLINGS);
        _refused(STAGE, MachineValidationErrors.InvalidSiblingsArrayLength.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, LONG_TX_SIBLINGS);
        _refused(STAGE, MachineValidationErrors.InvalidSiblingsArrayLength.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, ALTERED_IFLAGS_BLOCK);
        _refused(STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, ALTERED_HTIF_SIBLING);
        _refused(STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector);
        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, ALTERED_OUTPUTS_ROOT);
        _refused(STAGE, MachineValidationErrors.InvalidMachineMerkleProof.selector);

        handler.stageAs(BYSTANDER, 0, SETTLING_ONE, INTACT);
        _succeeded(STAGE);
        handler.elapseBy(PERIOD);
        handler.acceptAs(BYSTANDER, 0, REPORT_UNTOUCHED);
        _succeeded(ACCEPT);
        assertTrue(consensus.isOutputsMerkleRootValid(app, handler.outputsRootOf(SETTLING_ONE)));
        assertFalse(consensus.isOutputsMerkleRootValid(app, ~handler.outputsRootOf(SETTLING_ONE)));
    }

    /// @notice The last directed call was one the model allowed.
    function _succeeded(bytes4 action) private {
        assertEq(handler.performed(action), ++_expectedPerformed[action], "the call was expected to succeed");
        handler.assertModel();
    }

    /// @notice The last directed call was refused with `refusal`.
    function _refused(bytes4 action, bytes4 refusal) private {
        assertEq(
            handler.rejected(action, refusal),
            ++_expectedRejected[action][refusal],
            "the call was expected to be refused"
        );
        handler.assertModel();
    }

    function _stagedSnapshot() private view returns (bytes32) {
        (,,,, bool isStaged, uint256 stagingBlock, Machine.Hash state, bytes32 outputsRoot) =
            consensus.getCurrentSealedEpoch();
        return keccak256(abi.encode(isStaged, stagingBlock, state, outputsRoot));
    }
}
