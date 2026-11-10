// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.30;

import {Vm} from "forge-std-1.9.6/src/Vm.sol";

import {EmulatorConstants} from "cartesi-machine-solidity-step-0.15.0/src/EmulatorConstants.sol";

import {MachineValidationErrors} from "cartesi-rollups-contracts-3.0.0/src/common/MachineValidationErrors.sol";
import {MachineValidityProof} from "cartesi-rollups-contracts-3.0.0/src/common/MachineValidityProof.sol";
import {WithdrawalConfig} from "cartesi-rollups-contracts-3.0.0/src/common/WithdrawalConfig.sol";
import {IApplication} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplication.sol";
import {IApplicationChecker} from "cartesi-rollups-contracts-3.0.0/src/dapp/IApplicationChecker.sol";
import {IInputBox} from "cartesi-rollups-contracts-3.0.0/src/inputs/IInputBox.sol";
import {ConsensusTestUtils} from "cartesi-rollups-contracts-3.0.0/test/util/ConsensusTestUtils.sol";
import {LibEmulator} from "cartesi-rollups-contracts-3.0.0/test/util/LibEmulator.sol";

import {ITournament} from "prt-contracts/ITournament.sol";
import {ITournamentFactory} from "prt-contracts/ITournamentFactory.sol";
import {CartesiStateTransition} from "prt-contracts/state-transition/CartesiStateTransition.sol";
import {Tournament} from "prt-contracts/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "prt-contracts/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "prt-contracts/tournament/libs/Match.sol";
import {Time} from "prt-contracts/tournament/libs/Time.sol";
import {Machine} from "prt-contracts/types/Machine.sol";
import {Tree} from "prt-contracts/types/Tree.sol";

import {DaveAppFactory} from "src/DaveAppFactory.sol";
import {IDaveConsensus} from "src/IDaveConsensus.sol";
import {ISentryErrors} from "src/ISentryErrors.sol";

import {TableTournamentParametersProvider} from "prt-contracts-test/fixtures/TableTournamentParametersProvider.sol";
import {TournamentInspector} from "prt-contracts-test/fixtures/TournamentInspector.sol";

/// @notice Operations the walk tests require evidence of.
enum Tally {
    BACKLOGS,
    JOINS_BEYOND_THE_MODEL,
    ROOTS_WON_UNCONTESTED,
    ROOTS_WON_BY_FIRST_ENTRANT,
    ROOTS_WON_BY_SECOND_ENTRANT,
    ROOTS_LEFT_EMPTY,
    ROOTS_LOST_TO_DOUBLE_ELIMINATION,
    EPOCHS_STAGED,
    EPOCHS_ACCEPTED_BY_AGREEMENT,
    EPOCHS_ACCEPTED_BY_PERIOD,
    EPOCHS_ACCEPTED_WITH_BOTH,
    ACCEPTANCES_UNDER_A_REPLACED_REPORT,
    AGREEING_CLAIMS_AT_ACCEPTANCE,
    DISSENTING_CLAIMS_AT_ACCEPTANCE,
    ROTATIONS,
    ROTATIONS_OF_A_CLAIMED_SLOT,
    FORECLOSURES,
    BONDS_RECOVERED,
    BONDS_RECOVERED_WHILE_STAGED,
    BONDS_RECOVERED_FROM_A_RETIRED_ROOT,
    REPEATED_RECOVERIES,
    EPOCHS_SEALED_AT_CAPACITY,
    EPOCHS_SEALED_WITH_INPUTS_PENDING,
    INPUTS_BOUND,
    INPUTS_PADDED,
    INPUTS_MISMATCHED
}

/// @notice Geometry, actors and argument vocabulary shared by the handler
/// and the tests that direct it.
abstract contract DaveConsensusLifecycleVocabulary {
    uint64 internal constant ROOT_HEIGHT = 2;
    uint64 internal constant ROOT_ALLOWANCE = 16;
    uint64 internal constant RESPONSE_BUDGET = 2;
    uint64 internal constant DEPLOYMENT_BLOCK = 100;

    /// @dev Stated here, not imported: the epoch span is part of what the
    /// model checks.
    uint256 internal constant EPOCH_INPUT_CAPACITY = 1 << 24;

    bytes32 internal constant TEMPLATE = keccak256("template machine state");
    bytes32 internal constant UNPROVABLE_STATE = keccak256("state without a machine");

    address internal constant MANAGER = address(uint160(0x3A7A6E));
    address internal constant GUARDIAN = address(uint160(0x6A4D1A7));
    address internal constant BYSTANDER = address(uint160(0xB0B1));
    address internal constant SECOND_BYSTANDER = address(uint160(0xB0B2));
    address internal constant THIRD_BYSTANDER = address(uint160(0xB0B3));

    // Final states an entrant can commit to.
    uint8 internal constant SETTLING_ONE = 0;
    uint8 internal constant SETTLING_TWO = 1;
    uint8 internal constant UNSET_IFLAGS_Y = 2;
    uint8 internal constant NOT_ACCEPTED = 3;
    uint8 internal constant UNPROVABLE = 4;
    uint8 internal constant PROVABLE_MACHINES = 4;
    uint8 internal constant MACHINES = 5;

    // Ways a staging proof departs from the pool machine's own proof.
    uint8 internal constant INTACT = 0;
    uint8 internal constant SHORT_IFLAGS_SIBLINGS = 1;
    uint8 internal constant ALTERED_IFLAGS_BLOCK = 2;
    uint8 internal constant ALTERED_HTIF_SIBLING = 3;
    uint8 internal constant LONG_TX_SIBLINGS = 4;
    uint8 internal constant ALTERED_OUTPUTS_ROOT = 5;
    uint8 internal constant PROOF_ALTERATIONS = 6;

    // What the retiring tournament reports while acceptance runs.
    uint8 internal constant REPORT_UNTOUCHED = 0;
    uint8 internal constant REPORT_ANOTHER_WINNER = 1;
    uint8 internal constant REPORT_FAILED_ROOT = 2;
    uint8 internal constant REPORT_REVERTS = 3;
    uint8 internal constant REPORTS = 4;

    /// @dev Pool addresses beyond the initial sentries, free to rotate in.
    uint256 internal constant SPARE_SENTRIES = 3;
}

/// @notice Stateful model of one application's settlement. The production
/// InputBox, Application, DaveAppFactory, DaveConsensus, tournament factory
/// and Tournament are composed on an injected one-level root geometry.
///
/// Every action consults the ghost model before it calls: a call the model
/// allows must succeed, and a call the model forbids must revert with the
/// exact error the model names. Nothing is skipped on a precondition except
/// a join beyond the two entrants the model follows, which is tallied.
///
/// The model owns its own epoch bounds, input list, sentry slots and claims,
/// staged snapshot, settled values, and one clock model per root tournament.
/// It never reads a consensus getter to decide an expectation; getters are
/// read only by `assertModel`, which compares them with the model.
///
/// The seeded actions are a generator, not a specification: they favor the
/// arguments that let an epoch progress and, when time passes, usually let a
/// timely participant act first (`_passTimeTo`). Every call they make is
/// still checked against the model like any other.
///
/// What the model does not own. The dispute game itself: a root is driven
/// only as far as a root result needs (joins, one bisection response, timeout
/// claims, bond recovery), and which entrant holds the true state is the
/// caller's choice, since the state transition is never called. Machine
/// validity proofs come from the reference emulator model in LibEmulator, not
/// from a machine. A backlog beyond one epoch is written into the InputBox
/// length slot, so those inputs have no bytes. An input index whose position,
/// the epoch lower bound plus the index, exceeds uint256 is only required not
/// to bind an input: the consensus reverts there instead of padding.
contract DaveConsensusLifecycleHandler is ConsensusTestUtils, DaveConsensusLifecycleVocabulary {
    using LibEmulator for LibEmulator.ProofComponents;
    using LibEmulator for LibEmulator.State;
    using TournamentInspector for ITournament;

    error ModelLegalCallReverted(address target, bytes callData, bytes revertData);
    error ModelIllegalCallSucceeded(address target, bytes callData, bytes expectedError);
    error ModelIllegalCallRevertedOtherwise(address target, bytes callData, bytes expectedError, bytes revertData);

    uint8 private constant NONE = type(uint8).max;
    uint8 private constant ONE_WINS = 1;
    uint8 private constant TWO_WINS = 2;
    uint8 private constant ELIMINATE_BOTH = 3;
    uint256 private constant CLAIMABLE_STATES = MACHINES + 2;

    struct PoolMachine {
        bytes32 state;
        bytes32 outputsRoot;
        bytes proof;
    }

    struct Entrant {
        uint8 machine;
        address claimer;
        // Paused remainder, or the allowance behind a running deadline.
        uint64 allowance;
        // Zero while paused.
        uint64 startedAt;
    }

    struct Root {
        ITournament tournament;
        uint64 startedAt;
        uint256 bond;
        uint256 balance;
        uint8 entrants;
        uint8 dangling;
        bool matchLive;
        // The first entrant responded; the second must seal or time out.
        bool awaitingSeal;
        bool recovered;
        bool outcomeTallied;
        Entrant[2] entrant;
    }

    struct EntrantTree {
        bytes32 leaf0;
        bytes32 leaf1;
        bytes32 left;
        bytes32 right;
        bytes32 root;
        bytes32[] finalStateProof;
    }

    //
    // Deployment
    //

    IDaveConsensus public consensus;
    IApplication public app;
    IInputBox public inputBox;
    MultiLevelTournamentFactory public tournamentFactory;
    uint256 public sentryCount;
    uint256 public claimStagingPeriod;

    PoolMachine[4] internal _machines;

    //
    // Ghost model
    //

    uint256 internal _epoch;
    uint256 internal _lowerBound;
    uint256 internal _upperBound;
    uint256 internal _inputCount;
    uint256 internal _inputCountAtSealing;

    bytes32 internal _lastFinalizedState;
    mapping(bytes32 => bool) internal _settledOutputsRoot;

    bool internal _staged;
    bytes32 internal _stagedState;
    bytes32 internal _stagedOutputsRoot;
    uint256 internal _stagedAt;

    bool internal _foreclosed;
    bytes32 internal _frozenViews;

    // Empty for a backlog entry, whose InputBox hash is zero.
    mapping(uint256 => bytes) internal _input;
    mapping(uint256 => bytes32) internal _inputRoot;

    address[] internal _sentryPool;
    mapping(uint256 => address) internal _slotHolder;
    mapping(address => uint256) internal _slotOf;
    mapping(uint256 => mapping(uint256 => bool)) internal _claimed;
    mapping(uint256 => mapping(uint256 => bytes32)) internal _claim;

    // One root per sealed epoch; the last one is live.
    Root[] internal _roots;

    //
    // Evidence
    //

    mapping(bytes4 => uint256) public performed;
    mapping(bytes4 => mapping(bytes4 => uint256)) public rejected;
    mapping(Tally => uint256) internal _tallies;

    constructor(uint256 sentries, uint256 period) {
        vm.roll(DEPLOYMENT_BLOCK);
        sentryCount = sentries;
        claimStagingPeriod = period;
        inputBox = _contracts.core.inputBox;

        _buildMachine(SETTLING_ONE, _initSettlingOne);
        _buildMachine(SETTLING_TWO, _initSettlingTwo);
        _buildMachine(UNSET_IFLAGS_Y, _initUnsetIflagsY);
        _buildMachine(NOT_ACCEPTED, _initNotAccepted);

        uint64[] memory log2steps = new uint64[](1);
        uint64[] memory heights = new uint64[](1);
        heights[0] = ROOT_HEIGHT;
        tournamentFactory = new MultiLevelTournamentFactory(
            new Tournament(),
            new TableTournamentParametersProvider(
                log2steps,
                heights,
                Time.Duration.wrap(RESPONSE_BUDGET),
                Time.ZERO_DURATION,
                Time.Duration.wrap(ROOT_ALLOWANCE),
                ROOT_HEIGHT
            ),
            new CartesiStateTransition()
        );
        DaveAppFactory appFactory = new DaveAppFactory(inputBox, _contracts.core.applicationFactory, tournamentFactory);

        address[] memory initialSentries = new address[](sentries);
        for (uint256 i; i < sentries + SPARE_SENTRIES; ++i) {
            address member = address(uint160(uint256(keccak256(abi.encode("sentry pool", i)))));
            _sentryPool.push(member);
            if (i < sentries) {
                initialSentries[i] = member;
                _slotHolder[i + 1] = member;
                _slotOf[member] = i + 1;
            }
        }

        WithdrawalConfig memory withdrawalConfig;
        withdrawalConfig.guardian = GUARDIAN;

        vm.recordLogs();
        (app, consensus) =
            appFactory.newDaveApp(TEMPLATE, period, MANAGER, initialSentries, withdrawalConfig, bytes32(0));
        _openRoot(_createdTournament(vm.getRecordedLogs()), TEMPLATE);

        assertEq(address(consensus.getInputBox()), address(inputBox));
        assertEq(consensus.getApplicationContract(), address(app));
        assertEq(address(consensus.getTournamentFactory()), address(tournamentFactory));
        assertEq(consensus.getClaimStagingPeriod(), period);
        assertEq(consensus.getSentryManager(), MANAGER);
        assertEq(consensus.getNumberOfSentries(), sentries);
        assertEq(consensus.getDeploymentBlockNumber(), DEPLOYMENT_BLOCK);
        assertEq(app.getGuardian(), GUARDIAN);
        assertEq(address(app.getOutputsMerkleRootValidator()), address(consensus));
    }

    //
    // Seeded actions: the entry points of the invariant campaign and of the
    // seeded walks. Each decodes its seeds into one directed action below.
    //

    /// @notice The campaign's action distribution: a selector listed k times
    /// is drawn k times as often.
    function weightedSelectors() external pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](30);
        uint256 next;
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.addInput.selector, 2);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.elapse.selector, 5);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.joinRoot.selector, 3);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.respond.selector, 1);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.claimTimeout.selector, 2);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.recoverBond.selector, 2);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.stage.selector, 4);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.claim.selector, 4);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.accept.selector, 3);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.rotate.selector, 2);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.foreclose.selector, 1);
        next = _repeat(selectors, next, DaveConsensusLifecycleHandler.probeInput.selector, 1);
        assert(next == selectors.length);
    }

    function addInput(uint256 seed) external {
        if (_draw(seed, 0) % 16 == 0) {
            // Around one full span, so that sealing meets the capacity from
            // below, exactly, and from above.
            addInputBacklog(EPOCH_INPUT_CAPACITY - 2 + _draw(seed, 1) % 5);
        } else {
            addInputFrom(_bystander(_draw(seed, 1)), _payload(_draw(seed, 2)));
        }
    }

    function elapse(uint256 seed) external {
        uint256 mode = _draw(seed, 0) % 8;
        uint256 current = vm.getBlockNumber();
        uint256 boundary = _nextBoundary(current);
        uint256 target;
        if (boundary == 0 || mode < 2) {
            target = current + 1 + _draw(seed, 1) % 3;
        } else if (mode < 6) {
            target = boundary;
        } else if (mode == 6) {
            target = boundary - 1 > current ? boundary - 1 : boundary;
        } else {
            target = boundary + _draw(seed, 1) % ROOT_ALLOWANCE;
        }
        _passTimeTo(target, _draw(seed, 2));
    }

    function joinRoot(uint256 seed) external {
        joinRootWith(_machineFor(_draw(seed, 0)));
    }

    function respond() external {
        respondInMatch();
    }

    function claimTimeout(uint256 seed) external {
        claimTimeoutWith(_draw(seed, 0) % 4 == 0);
    }

    function recoverBond(uint256 seed) external {
        uint256 choice = _draw(seed, 0);
        // Mostly a retired root, where recovery is all that is left to do.
        recoverBondOf(_epoch == 0 || choice % 4 == 0 ? _epoch : (choice >> 8) % _epoch, _bystander(_draw(seed, 1)));
    }

    function stage(uint256 epochSeed, uint256 proofSeed) external {
        Root storage root = _roots[_epoch];
        uint256 choice = _draw(proofSeed, 0);
        uint8 proofMachine = uint8((choice >> 8) % PROVABLE_MACHINES);
        uint8 alteration = uint8((choice >> 16) % PROOF_ALTERATIONS);
        // Most draws carry the proof the model expects to settle.
        if (choice % 8 < 6 && root.dangling != NONE && root.entrant[root.dangling].machine < PROVABLE_MACHINES) {
            proofMachine = root.entrant[root.dangling].machine;
            alteration = INTACT;
        }
        stageAs(_bystander(_draw(proofSeed, 1)), _epochArgument(_draw(epochSeed, 0)), proofMachine, alteration);
    }

    function claim(uint256 callerSeed, uint256 epochSeed, uint256 stateSeed) external {
        if (sentryCount > 1 && _draw(callerSeed, 1) % 4 == 0) {
            // Sentries that computed the same state tend to vote together.
            bytes32 state = _claimedState(0);
            for (uint256 slot = 1; slot <= sentryCount; ++slot) {
                if (!_claimed[_epoch][slot]) {
                    claimAs(_slotHolder[slot], _epoch, state);
                }
            }
            return;
        }
        claimAs(
            _claimant(_draw(callerSeed, 0)), _epochArgument(_draw(epochSeed, 0)), _claimedState(_draw(stateSeed, 0))
        );
    }

    function accept(uint256 epochSeed, uint256 reportSeed) external {
        acceptAs(
            _bystander(_draw(reportSeed, 1)), _epochArgument(_draw(epochSeed, 0)), uint8(_draw(reportSeed, 0) % REPORTS)
        );
    }

    function rotate(uint256 callerSeed, uint256 currentSeed, uint256 nextSeed) external {
        uint256 who = _draw(callerSeed, 0);
        uint256 from = _draw(currentSeed, 0);
        uint256 to = _draw(nextSeed, 0);
        address current = sentryCount == 0 || from % 8 == 0
            ? _sentryPool[(from >> 8) % _sentryPool.length]
            : _slotHolder[1 + (from >> 8) % sentryCount];
        address next;
        if (to % 16 == 0) {
            next = address(0);
        } else if (to % 16 < 4) {
            next = _sentryPool[(to >> 8) % _sentryPool.length];
        } else {
            next = _spareSentry(to >> 8);
        }
        rotateAs(who % 8 == 0 ? _bystander(who >> 8) : MANAGER, current, next);
    }

    function foreclose(uint256 seed) external {
        forecloseAs(_draw(seed, 0) % 10 == 0 ? GUARDIAN : _bystander(_draw(seed, 1)));
    }

    function probeInput(uint256 indexSeed, uint256 bytesSeed) external {
        uint256 span = _upperBound - _lowerBound;
        uint256 choice = _draw(indexSeed, 0);
        uint256 index;
        if (span > 0 && choice % 4 != 0) {
            index = (choice >> 8) % span;
        } else if ((choice >> 8) % 4 == 0) {
            // The far end of the indices whose position still fits uint256.
            index = type(uint256).max - _lowerBound - (choice >> 16) % 3;
        } else {
            index = span + (choice >> 8) % 4;
        }
        probeInputWith(index, _probeBytes(_lowerBound + index, _draw(bytesSeed, 0)));
    }

    //
    // Directed actions
    //

    function addInputFrom(address sender, bytes memory payload) public {
        bytes memory expected;
        if (_foreclosed) {
            expected = _applicationForeclosed();
        }

        vm.recordLogs();
        (bool succeeded,) = _perform(
            sender, address(inputBox), 0, abi.encodeCall(IInputBox.addInput, (address(app), payload)), expected
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!succeeded) {
            return;
        }

        assertEq(logs.length, 1, "one InputAdded");
        assertEq(logs[0].emitter, address(inputBox));
        assertEq(logs[0].topics[0], IInputBox.InputAdded.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(app)))));
        assertEq(logs[0].topics[2], bytes32(_inputCount));
        bytes memory input = abi.decode(logs[0].data, (bytes));
        _input[_inputCount] = input;
        _inputRoot[_inputCount] = merkleRootOf(input);
        ++_inputCount;
    }

    /// @notice Grow the InputBox by `extra` inputs that have no bytes.
    /// @dev The InputBox refuses inputs after foreclosure, so this does too.
    function addInputBacklog(uint256 extra) public {
        if (_foreclosed) {
            addInputFrom(BYSTANDER, "");
            return;
        }
        bytes32 lengthSlot = keccak256(abi.encode(address(app), uint256(0)));
        assertEq(uint256(vm.load(address(inputBox), lengthSlot)), _inputCount, "InputBox length slot");
        vm.store(address(inputBox), lengthSlot, bytes32(_inputCount + extra));
        _inputCount += extra;
        ++_tallies[Tally.BACKLOGS];
    }

    function elapseBy(uint256 blocks) public {
        vm.roll(vm.getBlockNumber() + blocks);
        _tallyOutcome(_roots[_epoch]);
    }

    function joinRootWith(uint8 machine) public {
        Root storage root = _roots[_epoch];
        uint64 current = _now();
        bool closed = current >= root.startedAt + ROOT_ALLOWANCE;
        if (!closed && root.entrants == 2) {
            ++_tallies[Tally.JOINS_BEYOND_THE_MODEL];
            return;
        }

        bytes memory expected;
        if (closed) {
            expected = abi.encodeWithSelector(ITournament.TournamentIsClosed.selector);
        }

        uint8 index = root.entrants;
        address claimer = address(uint160(uint256(keccak256(abi.encode("claimer", address(this), _epoch, index)))));
        EntrantTree memory tree = _tree(_epoch, index, stateOf(machine));
        vm.deal(claimer, root.bond);
        (bool succeeded,) = _perform(
            claimer,
            address(root.tournament),
            root.bond,
            abi.encodeCall(
                ITournament.joinTournament,
                (
                    Machine.Hash.wrap(stateOf(machine)),
                    tree.finalStateProof,
                    Tree.Node.wrap(tree.left),
                    Tree.Node.wrap(tree.right)
                )
            ),
            expected
        );
        if (!succeeded) {
            vm.deal(claimer, 0);
            return;
        }

        Entrant storage entrant = root.entrant[index];
        entrant.machine = machine;
        entrant.claimer = claimer;
        entrant.allowance = ROOT_ALLOWANCE - (current - root.startedAt);
        entrant.startedAt = 0;
        root.balance += root.bond;
        ++root.entrants;
        if (index == 0) {
            root.dangling = 0;
        } else {
            // Pairing starts the elder clock only.
            root.dangling = NONE;
            root.matchLive = true;
            root.awaitingSeal = false;
            root.entrant[0].startedAt = current;
        }
    }

    /// @notice The first entrant's one bisection response.
    function respondInMatch() public {
        Root storage root = _roots[_epoch];
        uint64 current = _now();
        Entrant storage one = root.entrant[0];

        bytes memory expected;
        if (_finished(root, current)) {
            expected = abi.encodeWithSelector(ITournament.TournamentIsFinished.selector);
        } else if (!root.matchLive) {
            expected = abi.encodeWithSelector(ITournament.MatchDoesNotExist.selector);
        } else if (root.awaitingSeal) {
            expected = abi.encodeWithSelector(ITournament.MatchCannotBeAdvanced.selector);
        } else if (current - one.startedAt >= one.allowance) {
            expected = abi.encodeWithSelector(ITournament.CannotAdvanceTimedOutClock.selector);
        }

        EntrantTree memory tree = _entrantTree(root, 0);
        (bool succeeded,) = _perform(
            BYSTANDER,
            address(root.tournament),
            0,
            abi.encodeCall(
                ITournament.advanceMatch,
                (
                    _matchId(root),
                    Tree.Node.wrap(tree.left),
                    Tree.Node.wrap(tree.right),
                    Tree.Node.wrap(tree.leaf0),
                    Tree.Node.wrap(tree.leaf1)
                )
            ),
            expected
        );
        if (!succeeded) {
            return;
        }

        // A response is charged only beyond one response budget.
        uint64 elapsed = current - one.startedAt;
        if (elapsed > RESPONSE_BUDGET) {
            one.allowance -= elapsed - RESPONSE_BUDGET;
        }
        one.startedAt = 0;
        root.entrant[1].startedAt = current;
        root.awaitingSeal = true;
    }

    function claimTimeoutWith(bool eliminateBoth) public {
        Root storage root = _roots[_epoch];
        uint64 current = _now();
        (uint8 outcome, uint64 overdue) = _timeoutOutcome(root, current);

        bytes memory expected;
        if (_finished(root, current)) {
            expected = abi.encodeWithSelector(ITournament.TournamentIsFinished.selector);
        } else if (!root.matchLive) {
            expected = abi.encodeWithSelector(ITournament.MatchDoesNotExist.selector);
        } else if (eliminateBoth && outcome != ELIMINATE_BOTH) {
            expected = abi.encodeWithSelector(ITournament.MatchCannotBeEliminatedByTimeout.selector);
        } else if (!eliminateBoth && outcome != ONE_WINS && outcome != TWO_WINS) {
            expected = abi.encodeWithSelector(ITournament.MatchCannotBeWonByTimeout.selector);
        }

        uint8 winner = outcome == ONE_WINS ? 0 : 1;
        bytes memory callData;
        if (eliminateBoth) {
            callData = abi.encodeCall(ITournament.eliminateMatchByTimeout, (_matchId(root)));
        } else {
            EntrantTree memory tree = _entrantTree(root, winner);
            callData = abi.encodeCall(
                ITournament.winMatchByTimeout, (_matchId(root), Tree.Node.wrap(tree.left), Tree.Node.wrap(tree.right))
            );
        }
        (bool succeeded,) = _perform(BYSTANDER, address(root.tournament), 0, callData, expected);
        if (!succeeded) {
            return;
        }

        root.matchLive = false;
        if (!eliminateBoth) {
            // The paused winner pays the loser's overdue beyond one budget.
            if (overdue > RESPONSE_BUDGET) {
                root.entrant[winner].allowance -= overdue - RESPONSE_BUDGET;
            }
            root.dangling = winner;
        }
        _tallyOutcome(root);
    }

    function recoverBondOf(uint256 epochNumber, address caller) public {
        Root storage root = _roots[epochNumber];

        bytes memory expected;
        if (!_finished(root, _now())) {
            expected = abi.encodeWithSelector(ITournament.TournamentNotFinished.selector);
        } else if (root.dangling == NONE) {
            expected = abi.encodeWithSelector(ITournament.NoWinner.selector);
        }

        address claimer = root.dangling == NONE ? address(0) : root.entrant[root.dangling].claimer;
        uint256 claimerBalance = claimer.balance;
        uint256 burned = address(0).balance;
        (bool succeeded, bytes memory returned) =
            _perform(caller, address(root.tournament), 0, abi.encodeCall(ITournament.tryRecoveringBond, ()), expected);
        if (!succeeded) {
            return;
        }

        assertTrue(abi.decode(returned, (bool)), "recovery completes");
        if (root.recovered) {
            assertEq(claimer.balance, claimerBalance, "second recovery pays nothing");
            assertEq(address(0).balance, burned, "second recovery burns nothing");
            ++_tallies[Tally.REPEATED_RECOVERIES];
            return;
        }

        // One bond plus a tenth of the residual; the rest burns.
        uint256 payment = root.balance > root.bond ? root.bond + (root.balance - root.bond) / 10 : root.balance;
        assertEq(claimer.balance, claimerBalance + payment, "winner payment");
        assertEq(address(0).balance, burned + root.balance - payment, "burned residual");
        root.balance = 0;
        root.recovered = true;
        ++_tallies[Tally.BONDS_RECOVERED];
        if (epochNumber < _epoch) {
            ++_tallies[Tally.BONDS_RECOVERED_FROM_A_RETIRED_ROOT];
        } else if (_staged) {
            ++_tallies[Tally.BONDS_RECOVERED_WHILE_STAGED];
        }
    }

    function stageAs(address caller, uint256 epochNumber, uint8 proofMachine, uint8 alteration) public {
        Root storage root = _roots[_epoch];

        bytes memory expected;
        if (_foreclosed) {
            expected = _applicationForeclosed();
        } else if (epochNumber != _epoch) {
            expected = abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, epochNumber, _epoch);
        } else if (_staged) {
            expected = abi.encodeWithSelector(IDaveConsensus.TournamentResultAlreadyStaged.selector);
        } else if (!_finished(root, _now())) {
            expected = abi.encodeWithSelector(IDaveConsensus.TournamentNotFinishedYet.selector);
        } else if (root.dangling == NONE) {
            expected = abi.encodeWithSelector(ITournament.TournamentFailedNoWinner.selector);
        } else {
            expected = _proofVerdict(root.entrant[root.dangling].machine, proofMachine, alteration);
        }

        vm.recordLogs();
        (bool succeeded,) = _perform(
            caller,
            address(consensus),
            0,
            abi.encodeCall(IDaveConsensus.stageTournamentResult, (epochNumber, _proofOf(proofMachine, alteration))),
            expected
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!succeeded) {
            return;
        }

        uint8 winner = root.entrant[root.dangling].machine;
        _staged = true;
        _stagedState = stateOf(winner);
        _stagedOutputsRoot = _machines[winner].outputsRoot;
        _stagedAt = vm.getBlockNumber();
        ++_tallies[Tally.EPOCHS_STAGED];

        // Any tournament event here would mean staging touched its payment path.
        assertEq(logs.length, 1, "staging emits EpochStaged alone");
        assertEq(logs[0].emitter, address(consensus));
        assertEq(logs[0].topics[0], IDaveConsensus.EpochStaged.selector);
        assertEq(logs[0].topics[1], bytes32(_epoch));
        assertEq(logs[0].data, abi.encode(_stagedState, _stagedOutputsRoot));
    }

    function claimAs(address caller, uint256 epochNumber, bytes32 state) public {
        uint256 slot = _slotOf[caller];

        bytes memory expected;
        if (_foreclosed) {
            expected = _applicationForeclosed();
        } else if (slot == 0) {
            expected = abi.encodeWithSelector(IDaveConsensus.CallerIsNotSentry.selector, caller);
        } else if (epochNumber != _epoch) {
            expected = abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, epochNumber, _epoch);
        } else if (_claimed[_epoch][slot]) {
            expected = abi.encodeWithSelector(IDaveConsensus.SentryAlreadyClaimed.selector, epochNumber, slot);
        }

        vm.recordLogs();
        (bool succeeded,) = _perform(
            caller,
            address(consensus),
            0,
            abi.encodeCall(IDaveConsensus.submitSentryClaim, (epochNumber, Machine.Hash.wrap(state))),
            expected
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!succeeded) {
            return;
        }

        _claimed[_epoch][slot] = true;
        _claim[_epoch][slot] = state;

        assertEq(logs.length, 1, "one SentryClaim");
        assertEq(logs[0].emitter, address(consensus));
        assertEq(logs[0].topics[0], IDaveConsensus.SentryClaim.selector);
        assertEq(logs[0].topics[1], bytes32(_epoch));
        assertEq(logs[0].topics[2], bytes32(slot));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(caller))));
        assertEq(logs[0].data, abi.encode(state));
    }

    function acceptAs(address caller, uint256 epochNumber, uint8 report) public {
        bool unanimous = _unanimous();
        uint256 waited = _staged ? vm.getBlockNumber() - _stagedAt : 0;

        bytes memory expected;
        if (_foreclosed) {
            expected = _applicationForeclosed();
        } else if (epochNumber != _epoch) {
            expected = abi.encodeWithSelector(IDaveConsensus.IncorrectEpochNumber.selector, epochNumber, _epoch);
        } else if (!_staged) {
            expected = abi.encodeWithSelector(IDaveConsensus.TournamentResultNotStaged.selector);
        } else if (!unanimous && waited < claimStagingPeriod) {
            expected = abi.encodeWithSelector(
                IDaveConsensus.ClaimStagingPeriodNotOverYet.selector, waited, claimStagingPeriod
            );
        }

        // Whatever the retiring tournament says now must not matter.
        _replaceReport(_roots[_epoch].tournament, report);
        vm.recordLogs();
        (bool succeeded,) = _perform(
            caller,
            address(consensus),
            0,
            abi.encodeCall(IDaveConsensus.acceptStagedTournamentResult, (epochNumber)),
            expected
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.clearMockedCalls();
        if (!succeeded) {
            return;
        }

        if (!unanimous) {
            ++_tallies[Tally.EPOCHS_ACCEPTED_BY_PERIOD];
        } else if (waited < claimStagingPeriod) {
            ++_tallies[Tally.EPOCHS_ACCEPTED_BY_AGREEMENT];
        } else {
            ++_tallies[Tally.EPOCHS_ACCEPTED_WITH_BOTH];
        }
        if (report != REPORT_UNTOUCHED) {
            ++_tallies[Tally.ACCEPTANCES_UNDER_A_REPLACED_REPORT];
        }
        for (uint256 slot = 1; slot <= sentryCount; ++slot) {
            if (_claimed[_epoch][slot]) {
                bool agreed = _claim[_epoch][slot] == _stagedState;
                ++_tallies[agreed ? Tally.AGREEING_CLAIMS_AT_ACCEPTANCE : Tally.DISSENTING_CLAIMS_AT_ACCEPTANCE];
            }
        }

        // The snapshot is the final state the retiring tournament stored for
        // its winner, read from the tournament's storage, not from a view.
        {
            Root storage retiring = _roots[_epoch];
            (, Machine.Hash committed) =
                retiring.tournament.getCommitment(Tree.Node.wrap(_entrantTree(retiring, retiring.dangling).root));
            assertEq(Machine.Hash.unwrap(committed), _stagedState, "settled state is not the winner's");
        }

        // The staged snapshot settles, then one span of pending inputs seals.
        _settledOutputsRoot[_stagedOutputsRoot] = true;
        _lastFinalizedState = _stagedState;
        _staged = false;
        ++_epoch;
        _lowerBound = _upperBound;
        _inputCountAtSealing = _inputCount;
        uint256 pending = _inputCount - _lowerBound;
        _upperBound = _lowerBound + (pending < EPOCH_INPUT_CAPACITY ? pending : EPOCH_INPUT_CAPACITY);
        if (_upperBound - _lowerBound == EPOCH_INPUT_CAPACITY) {
            ++_tallies[Tally.EPOCHS_SEALED_AT_CAPACITY];
        }
        if (_upperBound < _inputCount) {
            ++_tallies[Tally.EPOCHS_SEALED_WITH_INPUTS_PENDING];
        }

        assertEq(logs.length, 2, "acceptance emits TournamentCreated then EpochSealed");
        ITournament next = _createdTournament(logs);
        assertEq(logs[1].emitter, address(consensus));
        assertEq(logs[1].topics[0], IDaveConsensus.EpochSealed.selector);
        assertEq(logs[1].topics[1], bytes32(_epoch));
        assertEq(logs[1].data, abi.encode(_lowerBound, _upperBound, _lastFinalizedState, _stagedOutputsRoot, next));
        _openRoot(next, _lastFinalizedState);
    }

    function rotateAs(address caller, address current, address next) public {
        uint256 slot = _slotOf[current];

        bytes memory expected;
        if (caller != MANAGER) {
            expected = abi.encodeWithSelector(IDaveConsensus.CallerIsNotSentryManager.selector, caller);
        } else if (_foreclosed) {
            expected = _applicationForeclosed();
        } else if (slot == 0) {
            expected = abi.encodeWithSelector(IDaveConsensus.CannotRotateNonSentry.selector, current);
        } else if (next == address(0)) {
            expected = abi.encodeWithSelector(ISentryErrors.ZeroSentryAddress.selector);
        } else if (_slotOf[next] != 0) {
            expected = abi.encodeWithSelector(ISentryErrors.DuplicatedSentryAddress.selector, _slotOf[next], next);
        }

        vm.recordLogs();
        (bool succeeded,) = _perform(
            caller, address(consensus), 0, abi.encodeCall(IDaveConsensus.rotateSentry, (current, next)), expected
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!succeeded) {
            return;
        }

        // The slot moves; whatever it claimed this epoch stays claimed.
        _slotOf[current] = 0;
        _slotOf[next] = slot;
        _slotHolder[slot] = next;
        ++_tallies[Tally.ROTATIONS];
        if (_claimed[_epoch][slot]) {
            ++_tallies[Tally.ROTATIONS_OF_A_CLAIMED_SLOT];
        }

        assertEq(logs.length, 1, "one SentryRotation");
        assertEq(logs[0].emitter, address(consensus));
        assertEq(logs[0].topics[0], IDaveConsensus.SentryRotation.selector);
        assertEq(logs[0].topics[1], bytes32(slot));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(current))));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(next))));
    }

    function forecloseAs(address caller) public {
        bytes memory expected;
        if (caller != GUARDIAN) {
            expected = abi.encodeWithSelector(IApplication.NotGuardian.selector);
        } else if (_foreclosed) {
            expected = abi.encodeWithSelector(IApplication.Foreclosed.selector);
        }

        (bool succeeded,) = _perform(caller, address(app), 0, abi.encodeCall(IApplication.foreclose, ()), expected);
        if (!succeeded) {
            return;
        }

        _foreclosed = true;
        _frozenViews = _viewDigest();
        ++_tallies[Tally.FORECLOSURES];
    }

    /// @param index An index within the sealed epoch whose position, the
    /// lower bound plus `index`, fits uint256.
    function probeInputWith(uint256 index, bytes memory data) public {
        uint256 position = _lowerBound + index;

        bytes memory expected;
        bytes32 expectedRoot;
        if (position < _upperBound) {
            bytes memory input = _input[position];
            bytes32 stored = input.length == 0 ? bytes32(0) : keccak256(input);
            if (keccak256(data) == stored) {
                expectedRoot = _inputRoot[position];
            } else {
                expected = abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(data), stored);
            }
        }

        (bool succeeded, bytes memory returned) = _perform(
            BYSTANDER,
            address(consensus),
            0,
            abi.encodeCall(consensus.provideMerkleRootOfInput, (index, data)),
            expected
        );
        if (!succeeded) {
            ++_tallies[Tally.INPUTS_MISMATCHED];
            return;
        }

        bytes32 root = abi.decode(returned, (bytes32));
        assertEq(root, expectedRoot, "input root");
        if (position < _upperBound) {
            assertNotEq(root, bytes32(0), "a sealed input has a root");
            ++_tallies[Tally.INPUTS_BOUND];
        } else {
            ++_tallies[Tally.INPUTS_PADDED];
        }
    }

    /// @notice One uncontested epoch: join, close, stage, wait, accept.
    function settleEpochWith(uint8 machine) external {
        joinRootWith(machine);
        elapseBy(ROOT_ALLOWANCE);
        stageAs(BYSTANDER, _epoch, machine, INTACT);
        elapseBy(claimStagingPeriod);
        acceptAs(BYSTANDER, _epoch, REPORT_UNTOUCHED);
    }

    //
    // Model against production
    //

    /// @notice Compare every consensus view with the ghost model.
    function assertModel() external view {
        _assertEpochBookkeeping();
        _assertSettledValues();
        _assertSentries();
        _assertReadiness();
        _assertInputBinding();
        _assertTournamentBalances();
        if (_foreclosed) {
            assertEq(_viewDigest(), _frozenViews, "a view moved after foreclosure");
        }
    }

    function _assertEpochBookkeeping() internal view {
        (
            uint256 epochNumber,
            uint256 lower,
            uint256 upper,
            ITournament tournament,
            bool isStaged,
            uint256 stagingBlock,
            Machine.Hash state,
            bytes32 outputsRoot
        ) = consensus.getCurrentSealedEpoch();
        assertEq(epochNumber, _epoch, "epoch number");
        assertEq(lower, _lowerBound, "lower bound");
        assertEq(upper, _upperBound, "upper bound");
        assertEq(_roots.length, _epoch + 1, "one root per sealed epoch");
        assertEq(address(tournament), address(_roots[_epoch].tournament), "live tournament");
        assertEq(isStaged, _staged, "staged flag");
        assertEq(stagingBlock, _staged ? _stagedAt : 0, "staging block");
        assertEq(Machine.Hash.unwrap(state), _staged ? _stagedState : bytes32(0), "staged state");
        assertEq(outputsRoot, _staged ? _stagedOutputsRoot : bytes32(0), "staged outputs root");

        assertLe(upper - lower, EPOCH_INPUT_CAPACITY, "span above capacity");
        assertLe(upper, _inputCountAtSealing, "sealed past the InputBox");
        assertEq(inputBox.getNumberOfInputs(address(app)), _inputCount, "InputBox count");

        uint256[8] memory indices = _finalityProbes();
        for (uint256 i; i < indices.length; ++i) {
            assertEq(
                consensus.wasInputFinalized(address(app), indices[i], i), indices[i] < _lowerBound, "input finality"
            );
        }
    }

    function _assertSettledValues() internal view {
        assertEq(consensus.getLastFinalizedMachineMerkleRoot(address(app)), _lastFinalizedState, "last finalized state");
        bytes32[11] memory roots = _outputsRootCandidates();
        for (uint256 i; i < roots.length; ++i) {
            assertEq(
                consensus.isOutputsMerkleRootValid(address(app), roots[i]),
                _settledOutputsRoot[roots[i]],
                "outputs root validity"
            );
        }
    }

    function _assertSentries() internal view {
        assertEq(consensus.getNumberOfSentries(), sentryCount, "sentry count");
        assertEq(consensus.getSentryById(0), address(0), "slot zero");
        assertEq(consensus.getSentryById(sentryCount + 1), address(0), "slot past the last");
        for (uint256 slot = 1; slot <= sentryCount; ++slot) {
            assertEq(consensus.getSentryById(slot), _slotHolder[slot], "slot holder");
        }
        for (uint256 i; i < _sentryPool.length; ++i) {
            assertEq(consensus.getSentryId(_sentryPool[i]), _slotOf[_sentryPool[i]], "slot of address");
        }

        // The previous, current and next epochs: claims land in the current
        // one only.
        for (uint256 e = _epoch == 0 ? 0 : _epoch - 1; e <= _epoch + 1; ++e) {
            for (uint256 slot; slot <= sentryCount + 1; ++slot) {
                assertEq(consensus.hasSentryClaimedInEpoch(e, slot), _claimed[e][slot], "claimed flag");
            }
        }
        for (uint256 i; i < CLAIMABLE_STATES; ++i) {
            bytes32 state = _claimableState(i);
            uint256 count;
            for (uint256 slot = 1; slot <= sentryCount; ++slot) {
                if (_claimed[_epoch][slot] && _claim[_epoch][slot] == state) {
                    ++count;
                }
            }
            assertEq(consensus.getSentryClaimCount(_epoch, Machine.Hash.wrap(state)), count, "claim count");
        }
    }

    function _assertReadiness() internal view {
        Root storage root = _roots[_epoch];
        bool finished = _finished(root, _now());
        bool won = finished && root.dangling != NONE;
        {
            (
                bool isFinished,
                bool isFailed,
                bool isStaged,
                uint256 epochNumber,
                Tree.Node winnerCommitment,
                Machine.Hash winnerState
            ) = consensus.canStageTournamentResult();
            assertEq(isFinished, finished, "root finished");
            assertEq(isFailed, finished && !won, "root failed");
            assertEq(isStaged, _staged, "staging readiness: staged");
            assertEq(epochNumber, _epoch, "staging readiness: epoch");
            assertEq(
                Tree.Node.unwrap(winnerCommitment),
                won ? _entrantTree(root, root.dangling).root : bytes32(0),
                "winner commitment"
            );
            assertEq(
                Machine.Hash.unwrap(winnerState),
                won ? stateOf(root.entrant[root.dangling].machine) : bytes32(0),
                "winner state"
            );
        }
        {
            (
                bool isStaged,
                bool agreed,
                bool periodOver,
                uint256 epochNumber,
                Machine.Hash state,
                bytes32 outputsRoot
            ) = consensus.canAcceptStagedTournamentResult();
            assertEq(isStaged, _staged, "acceptance readiness: staged");
            assertEq(epochNumber, _epoch, "acceptance readiness: epoch");
            assertEq(agreed, _staged && _unanimous(), "sentry agreement");
            assertEq(periodOver, _staged && vm.getBlockNumber() - _stagedAt >= claimStagingPeriod, "period over");
            assertEq(Machine.Hash.unwrap(state), _staged ? _stagedState : bytes32(0), "state to accept");
            assertEq(outputsRoot, _staged ? _stagedOutputsRoot : bytes32(0), "outputs root to accept");
        }
    }

    function _assertInputBinding() internal view {
        uint256 span = _upperBound - _lowerBound;
        assertEq(consensus.provideMerkleRootOfInput(span, ""), bytes32(0), "padding at the bound");
        assertEq(
            consensus.provideMerkleRootOfInput(type(uint256).max - _lowerBound, hex"00"),
            bytes32(0),
            "padding far past the bound"
        );
        if (span > 0) {
            _assertBound(0);
            _assertBound(span - 1);
        }
        if (_lowerBound > 0) {
            _assertNeverBound(0);
            _assertNeverBound(_lowerBound - 1);
        }
    }

    /// @notice The index whose position would wrap onto the settled input at
    /// `settled` must not bind that input's bytes. Reverting is tolerated.
    function _assertNeverBound(uint256 settled) internal view {
        uint256 index = type(uint256).max - _lowerBound + 1 + settled;
        try consensus.provideMerkleRootOfInput(index, _input[settled]) returns (bytes32 root) {
            assertEq(root, bytes32(0), "a position past uint256 bound a settled input");
        } catch {}
    }

    function _assertBound(uint256 index) internal view {
        uint256 position = _lowerBound + index;
        bytes memory input = _input[position];
        bytes32 stored;
        if (input.length != 0) {
            stored = keccak256(input);
            assertEq(consensus.provideMerkleRootOfInput(index, input), _inputRoot[position], "bound input root");
        }

        bytes memory other = abi.encodePacked(input, hex"00");
        try consensus.provideMerkleRootOfInput(index, other) returns (bytes32) {
            assertTrue(false, "other bytes accepted for a sealed input");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IDaveConsensus.InputHashMismatch.selector, keccak256(other), stored),
                "mismatch names both hashes"
            );
        }
    }

    /// @dev Consensus calls never move tournament value: a balance changes
    /// only at a join and at an explicit recovery.
    function _assertTournamentBalances() internal view {
        for (uint256 i; i < _roots.length; ++i) {
            assertEq(address(_roots[i].tournament).balance, _roots[i].balance, "tournament balance");
        }
    }

    /// @notice One hash over every consensus view backed by storage.
    /// @dev The two readiness views are left out: they read the live
    /// tournament and the block number, foreclosed or not, so they keep
    /// moving. `_assertReadiness` compares them with the model instead.
    function _viewDigest() internal view returns (bytes32 digest) {
        address application = address(app);
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getCurrentSealedEpoch, ()));
        digest = _fold(digest, abi.encodeCall(consensus.getLastFinalizedMachineMerkleRoot, (application)));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getInputBox, ()));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getApplicationContract, ()));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getTournamentFactory, ()));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getClaimStagingPeriod, ()));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getSentryManager, ()));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getNumberOfSentries, ()));
        digest = _fold(digest, abi.encodeCall(IDaveConsensus.getDeploymentBlockNumber, ()));
        digest = keccak256(abi.encode(digest, inputBox.getNumberOfInputs(application)));

        bytes32[11] memory roots = _outputsRootCandidates();
        for (uint256 i; i < roots.length; ++i) {
            digest = _fold(digest, abi.encodeCall(consensus.isOutputsMerkleRootValid, (application, roots[i])));
        }
        uint256[8] memory indices = _finalityProbes();
        for (uint256 i; i < indices.length; ++i) {
            digest = _fold(digest, abi.encodeCall(consensus.wasInputFinalized, (application, indices[i], i)));
        }
        for (uint256 i; i < _sentryPool.length; ++i) {
            digest = _fold(digest, abi.encodeCall(IDaveConsensus.getSentryId, (_sentryPool[i])));
        }
        for (uint256 slot; slot <= sentryCount + 1; ++slot) {
            digest = _fold(digest, abi.encodeCall(IDaveConsensus.getSentryById, (slot)));
            for (uint256 e = _epoch == 0 ? 0 : _epoch - 1; e <= _epoch + 1; ++e) {
                digest = _fold(digest, abi.encodeCall(IDaveConsensus.hasSentryClaimedInEpoch, (e, slot)));
            }
        }
        for (uint256 i; i < CLAIMABLE_STATES; ++i) {
            digest = _fold(
                digest,
                abi.encodeCall(IDaveConsensus.getSentryClaimCount, (_epoch, Machine.Hash.wrap(_claimableState(i))))
            );
        }

        // Right bytes, other bytes, and the padding at the bound.
        uint256 span = _upperBound - _lowerBound;
        digest = _fold(digest, abi.encodeCall(consensus.provideMerkleRootOfInput, (span, "")));
        if (span > 0) {
            bytes memory input = _input[_lowerBound];
            digest = _fold(digest, abi.encodeCall(consensus.provideMerkleRootOfInput, (0, input)));
            digest = _fold(
                digest, abi.encodeCall(consensus.provideMerkleRootOfInput, (0, abi.encodePacked(input, hex"00")))
            );
        }
    }

    function _fold(bytes32 digest, bytes memory query) internal view returns (bytes32) {
        (bool succeeded, bytes memory answer) = address(consensus).staticcall(query);
        return keccak256(abi.encode(digest, succeeded, answer));
    }

    //
    // Read access for tests
    //

    function tallies() external view returns (uint256[] memory values) {
        values = new uint256[](uint256(type(Tally).max) + 1);
        for (uint256 i; i < values.length; ++i) {
            values[i] = _tallies[Tally(i)];
        }
    }

    function tally(Tally kind) external view returns (uint256) {
        return _tallies[kind];
    }

    function stateOf(uint8 machine) public view returns (bytes32) {
        return machine == UNPROVABLE ? UNPROVABLE_STATE : _machines[machine].state;
    }

    function outputsRootOf(uint8 machine) external view returns (bytes32) {
        return _machines[machine].outputsRoot;
    }

    function _proofOf(uint8 machine, uint8 alteration) internal view returns (MachineValidityProof memory proof) {
        proof = abi.decode(_machines[machine].proof, (MachineValidityProof));
        if (alteration == SHORT_IFLAGS_SIBLINGS) {
            proof.iflagsYProof.siblings = _resized(proof.iflagsYProof.siblings, proof.iflagsYProof.siblings.length - 1);
        } else if (alteration == ALTERED_IFLAGS_BLOCK) {
            proof.iflagsYProof.dataBlock = ~proof.iflagsYProof.dataBlock;
        } else if (alteration == ALTERED_HTIF_SIBLING) {
            proof.htifTohostProof.siblings[7] = ~proof.htifTohostProof.siblings[7];
        } else if (alteration == LONG_TX_SIBLINGS) {
            proof.txBufferProof.siblings =
                _resized(proof.txBufferProof.siblings, proof.txBufferProof.siblings.length + 1);
        } else if (alteration == ALTERED_OUTPUTS_ROOT) {
            proof.txBufferProof.dataBlock = _alteredOutputsRoot(machine);
        }
    }

    function sentryAt(uint256 slot) external view returns (address) {
        return _slotHolder[slot];
    }

    function spareSentry(uint256 index) external view returns (address) {
        return _spareSentry(index);
    }

    function inputAt(uint256 position) external view returns (bytes memory) {
        return _input[position];
    }

    /// @notice Root of the smallest zero-padded tree of 32-byte blocks that
    /// fits `data`, folded level by level.
    function merkleRootOf(bytes memory data) public pure returns (bytes32) {
        uint256 blocks = 1;
        while (blocks * 32 < data.length) {
            blocks *= 2;
        }
        bytes32[] memory level = new bytes32[](blocks);
        for (uint256 i; i < blocks; ++i) {
            bytes32 word;
            uint256 offset = 32 * i;
            if (offset < data.length) {
                assembly ("memory-safe") {
                    word := mload(add(add(data, 32), offset))
                }
                uint256 available = data.length - offset;
                if (available < 32) {
                    word &= bytes32(type(uint256).max << (8 * (32 - available)));
                }
            }
            level[i] = keccak256(abi.encode(word));
        }
        while (blocks > 1) {
            blocks /= 2;
            for (uint256 i; i < blocks; ++i) {
                level[i] = keccak256(abi.encode(level[2 * i], level[2 * i + 1]));
            }
        }
        return level[0];
    }

    //
    // Model internals
    //

    function _perform(address caller, address target, uint256 value, bytes memory callData, bytes memory expectedError)
        internal
        returns (bool succeeded, bytes memory returned)
    {
        vm.prank(caller);
        (succeeded, returned) = target.call{value: value}(callData);
        if (expectedError.length == 0) {
            require(succeeded, ModelLegalCallReverted(target, callData, returned));
            ++performed[_selectorOf(callData)];
        } else {
            require(!succeeded, ModelIllegalCallSucceeded(target, callData, expectedError));
            require(
                keccak256(returned) == keccak256(expectedError),
                ModelIllegalCallRevertedOtherwise(target, callData, expectedError, returned)
            );
            ++rejected[_selectorOf(callData)][_selectorOf(expectedError)];
        }
    }

    function _selectorOf(bytes memory encoded) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(encoded, 32))
        }
    }

    /// @notice The first failing check of a staging proof, or nothing.
    /// @dev A result is stageable when the proof opens the winner's state at
    /// iflags.Y, HTIF tohost and the first TX-buffer block, in that order,
    /// and the state is a manual yield that accepted its input.
    function _proofVerdict(uint8 winner, uint8 proofMachine, uint8 alteration) internal pure returns (bytes memory) {
        if (alteration == SHORT_IFLAGS_SIBLINGS) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidSiblingsArrayLength.selector);
        }
        if (proofMachine != winner || alteration == ALTERED_IFLAGS_BLOCK) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidMachineMerkleProof.selector);
        }
        if (winner == UNSET_IFLAGS_Y) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidPostEpochMachineIflagsYRegister.selector);
        }
        if (alteration == ALTERED_HTIF_SIBLING) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidMachineMerkleProof.selector);
        }
        if (winner == NOT_ACCEPTED) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidPostEpochMachineHtifTohostRegister.selector);
        }
        if (alteration == LONG_TX_SIBLINGS) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidSiblingsArrayLength.selector);
        }
        if (alteration == ALTERED_OUTPUTS_ROOT) {
            return abi.encodeWithSelector(MachineValidationErrors.InvalidMachineMerkleProof.selector);
        }
        return "";
    }

    function _unanimous() internal view returns (bool) {
        if (sentryCount == 0) {
            return false;
        }
        for (uint256 slot = 1; slot <= sentryCount; ++slot) {
            if (!_claimed[_epoch][slot] || _claim[_epoch][slot] != _stagedState) {
                return false;
            }
        }
        return true;
    }

    function _finished(Root storage root, uint64 current) internal view returns (bool) {
        return current >= root.startedAt + ROOT_ALLOWANCE && !root.matchLive;
    }

    /// @return deadline The first block at which the responder has timed out
    /// @return eliminableAt The first block at which neither side survives
    function _matchSchedule(Root storage root) internal view returns (uint64 deadline, uint64 eliminableAt) {
        Entrant storage responder = root.entrant[root.awaitingSeal ? 1 : 0];
        Entrant storage waiting = root.entrant[root.awaitingSeal ? 0 : 1];
        deadline = responder.startedAt + responder.allowance;
        eliminableAt = deadline + waiting.allowance;
    }

    function _timeoutOutcome(Root storage root, uint64 current) internal view returns (uint8 outcome, uint64 overdue) {
        if (!root.matchLive) {
            return (0, 0);
        }
        (uint64 deadline, uint64 eliminableAt) = _matchSchedule(root);
        if (current < deadline) {
            return (0, 0);
        }
        if (current >= eliminableAt) {
            return (ELIMINATE_BOTH, 0);
        }
        return (root.awaitingSeal ? ONE_WINS : TWO_WINS, current - deadline);
    }

    function _tallyOutcome(Root storage root) internal {
        if (root.outcomeTallied || !_finished(root, _now())) {
            return;
        }
        root.outcomeTallied = true;
        Tally kind;
        if (root.dangling == NONE) {
            kind = root.entrants == 0 ? Tally.ROOTS_LEFT_EMPTY : Tally.ROOTS_LOST_TO_DOUBLE_ELIMINATION;
        } else if (root.entrants == 1) {
            kind = Tally.ROOTS_WON_UNCONTESTED;
        } else {
            kind = root.dangling == 0 ? Tally.ROOTS_WON_BY_FIRST_ENTRANT : Tally.ROOTS_WON_BY_SECOND_ENTRANT;
        }
        ++_tallies[kind];
    }

    function _openRoot(ITournament tournament, bytes32 initialState) internal {
        for (uint256 i; i < _roots.length; ++i) {
            assertNotEq(address(_roots[i].tournament), address(tournament), "a tournament served two epochs");
        }
        // Clone arguments, not a consensus getter: the root starts from the
        // settled state and asks this consensus for its inputs.
        ITournament.TournamentArguments memory arguments = tournament.tournamentArguments();
        assertEq(Machine.Hash.unwrap(arguments.commitmentArgs.initialHash), initialState, "root initial state");
        assertEq(address(arguments.provider), address(consensus), "root data provider");
        assertEq(arguments.level, 0);
        assertEq(arguments.commitmentArgs.height, ROOT_HEIGHT);
        assertEq(Time.Instant.unwrap(arguments.startInstant), _now(), "root start");
        assertEq(Time.Duration.unwrap(arguments.allowance), ROOT_ALLOWANCE);

        Root storage root = _roots.push();
        root.tournament = tournament;
        root.startedAt = _now();
        root.bond = tournament.bondValue();
        root.dangling = NONE;
    }

    /// @notice The one tournament the factory created in `logs`.
    function _createdTournament(Vm.Log[] memory logs) internal view returns (ITournament tournament) {
        uint256 created;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(tournamentFactory)
                    && logs[i].topics[0] == ITournamentFactory.TournamentCreated.selector
            ) {
                (address clone,,) = abi.decode(logs[i].data, (address, ITournament.TournamentDescriptor, uint256));
                tournament = ITournament(clone);
                ++created;
            }
        }
        assertEq(created, 1, "one tournament per sealing");
    }

    function _replaceReport(ITournament tournament, uint8 report) internal {
        bytes memory query = abi.encodeCall(ITournament.tournamentStanding, ());
        ITournament.TournamentStandingView memory standing;
        standing.finishedAt = Time.Instant.wrap(_now());
        if (report == REPORT_ANOTHER_WINNER) {
            standing.standing = ITournament.TournamentStanding.ROOT_WINNER;
            standing.hasCandidate = true;
            standing.candidate = Tree.Node.wrap(keccak256("another candidate"));
            standing.finalState =
                Machine.Hash.wrap(stateOf(_stagedState == stateOf(SETTLING_ONE) ? SETTLING_TWO : SETTLING_ONE));
            vm.mockCall(address(tournament), query, abi.encode(standing));
        } else if (report == REPORT_FAILED_ROOT) {
            standing.standing = ITournament.TournamentStanding.ROOT_FAILED;
            vm.mockCall(address(tournament), query, abi.encode(standing));
        } else if (report == REPORT_REVERTS) {
            vm.mockCallRevert(address(tournament), query, "tournament unavailable");
        }
    }

    function _applicationForeclosed() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IApplicationChecker.ApplicationForeclosed.selector, address(app));
    }

    //
    // Commitments: complete height-two trees ending in the final state
    //

    function _tree(uint256 epochNumber, uint256 entrant, bytes32 finalState)
        internal
        view
        returns (EntrantTree memory tree)
    {
        tree.leaf0 = keccak256(abi.encode(address(this), epochNumber, entrant, uint256(0)));
        tree.leaf1 = keccak256(abi.encode(address(this), epochNumber, entrant, uint256(1)));
        bytes32 leaf2 = keccak256(abi.encode(address(this), epochNumber, entrant, uint256(2)));
        tree.left = keccak256(abi.encode(tree.leaf0, tree.leaf1));
        tree.right = keccak256(abi.encode(leaf2, finalState));
        tree.root = keccak256(abi.encode(tree.left, tree.right));
        tree.finalStateProof = new bytes32[](2);
        tree.finalStateProof[0] = leaf2;
        tree.finalStateProof[1] = tree.left;
    }

    /// @notice The tree of an entrant of the live root.
    /// @dev An entrant that never joined still has a tree, so that calls on
    /// a match that does not exist carry a well-formed id.
    function _entrantTree(Root storage root, uint8 index) internal view returns (EntrantTree memory) {
        return _tree(_epoch, index, stateOf(root.entrant[index].machine));
    }

    function _matchId(Root storage root) internal view returns (Match.Id memory) {
        return Match.Id(Tree.Node.wrap(_entrantTree(root, 0).root), Tree.Node.wrap(_entrantTree(root, 1).root));
    }

    //
    // Pool machines: deterministic states of the reference emulator model
    //

    function _buildMachine(uint8 index, function(LibEmulator.State storage) init) private {
        LibEmulator.ProofComponents memory components = _newProofComponents(init);
        _machines[index].state = components.getMachineMerkleRoot();
        _machines[index].outputsRoot = components.outputsMerkleRoot;
        _machines[index].proof = abi.encode(components.getMachineValidityProof());
    }

    function _initSettlingOne(LibEmulator.State storage emulator) internal {
        emulator.setIflagsY(1);
        emulator.setHtifTohostRxAccepted();
        emulator.addAccount(hex"a1");
        emulator.addOutput(hex"01");
    }

    function _initSettlingTwo(LibEmulator.State storage emulator) internal {
        emulator.setIflagsY(1);
        emulator.setHtifTohostRxAccepted();
        emulator.addAccount(hex"a2a2");
        emulator.addOutput(hex"0202");
    }

    function _initUnsetIflagsY(LibEmulator.State storage emulator) internal {
        emulator.setIflagsY(0);
        emulator.setHtifTohostRxAccepted();
        emulator.addAccount(hex"a3a3a3");
        emulator.addOutput(hex"030303");
    }

    /// @dev A manual yield that rejected its input.
    function _initNotAccepted(LibEmulator.State storage emulator) internal {
        emulator.setIflagsY(1);
        emulator.setHtifTohost(
            EmulatorConstants.HTIF_DEV_YIELD,
            EmulatorConstants.HTIF_YIELD_CMD_MANUAL,
            EmulatorConstants.HTIF_YIELD_MANUAL_REASON_RX_REJECTED
        );
        emulator.addAccount(hex"a4a4a4a4");
        emulator.addOutput(hex"04040404");
    }

    function _alteredOutputsRoot(uint8 machine) internal view returns (bytes32) {
        return ~_machines[machine].outputsRoot;
    }

    //
    // Probes and seed decoding
    //

    /// @notice Every outputs root a staging attempt can carry, plus decoys.
    function _outputsRootCandidates() internal view returns (bytes32[11] memory roots) {
        for (uint8 machine; machine < PROVABLE_MACHINES; ++machine) {
            roots[2 * machine] = _machines[machine].outputsRoot;
            roots[2 * machine + 1] = _alteredOutputsRoot(machine);
        }
        roots[8] = bytes32(0);
        roots[9] = stateOf(SETTLING_ONE);
        roots[10] = TEMPLATE;
    }

    function _finalityProbes() internal view returns (uint256[8] memory indices) {
        indices[0] = 0;
        indices[1] = _lowerBound == 0 ? 0 : _lowerBound - 1;
        indices[2] = _lowerBound;
        indices[3] = _lowerBound + 1;
        indices[4] = _upperBound == 0 ? 0 : _upperBound - 1;
        indices[5] = _upperBound;
        indices[6] = _inputCount;
        indices[7] = type(uint256).max;
    }

    /// @notice The states a seeded sentry claims: the pool, the template, zero.
    function _claimableState(uint256 index) internal view returns (bytes32) {
        for (uint8 machine; machine < MACHINES; ++machine) {
            if (machine == index) {
                return stateOf(machine);
            }
        }
        return index == MACHINES ? TEMPLATE : bytes32(0);
    }

    function _claimedState(uint256 choice) internal view returns (bytes32) {
        if (choice % 16 >= 13) {
            return _claimableState((choice >> 8) % CLAIMABLE_STATES);
        }
        // Most draws vote for what the model expects to settle.
        if (_staged) {
            return _stagedState;
        }
        Root storage root = _roots[_epoch];
        if (root.dangling != NONE) {
            return stateOf(root.entrant[root.dangling].machine);
        }
        return stateOf(root.entrants == 2 ? root.entrant[1].machine : SETTLING_ONE);
    }

    function _claimant(uint256 choice) internal view returns (address) {
        uint256 kind = choice % 8;
        if (sentryCount == 0 || kind == 7) {
            return _bystander(choice >> 8);
        }
        if (kind == 6) {
            return _spareSentry(choice >> 8);
        }
        uint256 slot = 1 + (choice >> 8) % sentryCount;
        if (kind < 5) {
            // Prefer a slot that has not claimed in this epoch.
            for (uint256 i; i < sentryCount && _claimed[_epoch][slot]; ++i) {
                slot = 1 + slot % sentryCount;
            }
        }
        return _slotHolder[slot];
    }

    function _epochArgument(uint256 choice) internal view returns (uint256) {
        uint256 kind = choice % 16;
        if (kind < 13) {
            return _epoch;
        }
        if (kind == 13) {
            return _epoch + 1;
        }
        if (kind == 14) {
            return _epoch == 0 ? 2 : _epoch - 1;
        }
        return choice;
    }

    function _machineFor(uint256 choice) internal pure returns (uint8) {
        uint256 kind = choice % 64;
        if (kind < 32) {
            return SETTLING_ONE;
        }
        if (kind < 58) {
            return SETTLING_TWO;
        }
        if (kind < 60) {
            return UNSET_IFLAGS_Y;
        }
        if (kind < 62) {
            return NOT_ACCEPTED;
        }
        return UNPROVABLE;
    }

    /// @notice A caller with no role, the manager, or a pool sentry; never
    /// the guardian, whose only move is `foreclose`.
    function _bystander(uint256 choice) internal view returns (address) {
        uint256 kind = choice % 8;
        if (kind == 6) {
            return MANAGER;
        }
        if (kind == 7) {
            return _sentryPool[(choice >> 8) % _sentryPool.length];
        }
        if (kind % 3 == 0) {
            return BYSTANDER;
        }
        return kind % 3 == 1 ? SECOND_BYSTANDER : THIRD_BYSTANDER;
    }

    /// @notice A pool address that holds no slot now.
    function _spareSentry(uint256 choice) internal view returns (address spare) {
        uint256 start = choice % _sentryPool.length;
        for (uint256 i; i < _sentryPool.length; ++i) {
            spare = _sentryPool[(start + i) % _sentryPool.length];
            if (_slotOf[spare] == 0) {
                return spare;
            }
        }
    }

    function _payload(uint256 choice) internal pure returns (bytes memory payload) {
        payload = new bytes(choice % 80);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = bytes1(uint8(uint256(keccak256(abi.encode(choice, i)))));
        }
    }

    function _probeBytes(uint256 position, uint256 choice) internal view returns (bytes memory) {
        bytes memory input = _input[position];
        uint256 kind = choice % 8;
        if (kind < 3) {
            return input;
        }
        if (kind == 3 && input.length != 0) {
            input[input.length - 1] = ~input[input.length - 1];
            return input;
        }
        if (kind == 4) {
            return abi.encodePacked(input, hex"00");
        }
        if (kind == 5 && position > 0) {
            return _input[position - 1];
        }
        if (kind == 6) {
            return "";
        }
        return _payload(choice >> 8);
    }

    /// @notice The next block at which something in the model changes:
    /// the root closes, a match clock runs out, or the staging period ends.
    /// Zero when nothing is scheduled.
    function _nextBoundary(uint256 current) internal view returns (uint256 boundary) {
        Root storage root = _roots[_epoch];
        boundary = _earlier(boundary, root.startedAt + ROOT_ALLOWANCE, current);
        if (root.matchLive) {
            (uint64 deadline, uint64 eliminableAt) = _matchSchedule(root);
            boundary = _earlier(boundary, deadline, current);
            boundary = _earlier(boundary, eliminableAt, current);
        }
        if (_staged) {
            boundary = _earlier(boundary, _stagedAt + claimStagingPeriod, current);
        }
    }

    function _earlier(uint256 best, uint256 candidate, uint256 current) internal pure returns (uint256) {
        if (candidate > current && (best == 0 || candidate < best)) {
            return candidate;
        }
        return best;
    }

    /// @notice Roll to `target`, often letting a timely participant act
    /// first. An entrant joins an empty root before it closes, sometimes
    /// followed by a challenger; the first entrant sometimes answers its
    /// match; a timeout is claimed before both sides become eliminable; and
    /// a result every sentry voted for is accepted before its period ends.
    /// Without that bias most roots would end without a winner, which holds
    /// the epoch for good, and few results would settle by agreement.
    function _passTimeTo(uint256 target, uint256 choice) internal {
        Root storage root = _roots[_epoch];
        uint64 current = _now();
        if (current < root.startedAt + ROOT_ALLOWANCE && target >= root.startedAt + ROOT_ALLOWANCE) {
            if (root.entrants == 0 && choice % 8 != 0) {
                joinRootWith(_machineFor(choice >> 8));
            }
            if (root.entrants == 1 && (choice >> 16) % 4 == 0) {
                joinRootWith(_machineFor(choice >> 24));
            }
        }
        if (root.matchLive) {
            Entrant storage one = root.entrant[0];
            if (!root.awaitingSeal && current - one.startedAt < one.allowance && (choice >> 32) % 3 == 0) {
                respondInMatch();
            }
            (uint64 deadline, uint64 eliminableAt) = _matchSchedule(root);
            if (current < eliminableAt && target >= eliminableAt && (choice >> 40) % 4 != 0) {
                if (current < deadline) {
                    vm.roll(deadline);
                }
                claimTimeoutWith(false);
            }
        }
        if (
            _staged && _unanimous() && _now() < _stagedAt + claimStagingPeriod
                && target >= _stagedAt + claimStagingPeriod && (choice >> 48) % 2 == 0
        ) {
            acceptAs(BYSTANDER, _epoch, REPORT_UNTOUCHED);
        }
        vm.roll(target);
        _tallyOutcome(_roots[_epoch]);
    }

    function _repeat(bytes4[] memory selectors, uint256 next, bytes4 selector, uint256 times)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < times; ++i) {
            selectors[next++] = selector;
        }
        return next;
    }

    function _resized(bytes32[] memory array, uint256 length) private pure returns (bytes32[] memory resized) {
        resized = new bytes32[](length);
        for (uint256 i; i < length && i < array.length; ++i) {
            resized[i] = array[i];
        }
    }

    /// @dev Hashed so that the small and repeated values a fuzzer favors
    /// still spread over every choice.
    function _draw(uint256 seed, uint256 salt) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockNumber());
    }
}
