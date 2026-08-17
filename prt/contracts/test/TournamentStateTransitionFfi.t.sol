// Copyright Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.22;

import {IDataProvider} from "src/IDataProvider.sol";
import {ITournament} from "src/ITournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Match} from "src/tournament/libs/Match.sol";
import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

import {Util} from "./Util.sol";

contract ExactInputProvider is IDataProvider {
    uint256 private immutable EXPECTED_INDEX;
    bytes private expectedInput;
    bytes32 private immutable INPUT_ROOT;

    error UnexpectedInputIndex(uint256 expected, uint256 actual);
    error UnexpectedInput(bytes expected, bytes actual);

    constructor(uint256 expectedIndex, bytes memory input, bytes32 inputRoot) {
        EXPECTED_INDEX = expectedIndex;
        expectedInput = input;
        INPUT_ROOT = inputRoot;
    }

    function provideMerkleRootOfInput(
        uint256 inputIndexWithinEpoch,
        bytes calldata input
    ) external view returns (bytes32) {
        require(
            inputIndexWithinEpoch == EXPECTED_INDEX,
            UnexpectedInputIndex(EXPECTED_INDEX, inputIndexWithinEpoch)
        );
        require(
            keccak256(input) == keccak256(expectedInput),
            UnexpectedInput(expectedInput, input)
        );
        return INPUT_ROOT;
    }
}

contract TournamentStateTransitionFfiTest is Util {
    using Tree for Tree.Node;

    Machine.Hash private constant CORRECT_FINAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xcafe)));
    Machine.Hash private constant INCORRECT_FINAL_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xdead)));
    Machine.Hash private constant INCORRECT_STEP_STATE =
        Machine.Hash.wrap(bytes32(uint256(0xbad)));

    function testLeafWinComposesRealStfWithGenericInputProvider() public {
        (bytes32 beforeState, bytes32 nextState, bytes memory stepProof) =
            _inputOpeningVector();
        bytes memory expectedInput = abi.encodePacked(bytes32(0));
        // The canonical index-zero fixture input is exactly one Merkle leaf.
        ExactInputProvider provider =
            new ExactInputProvider(0, expectedInput, keccak256(expectedInput));
        MultiLevelTournamentFactory factory =
            Util.instantiateSingleLevelTournamentFactory(0, 1);
        ITournament tournament =
            factory.instantiate(Machine.Hash.wrap(beforeState), provider);

        Tree.Node nextNode = Tree.Node.wrap(nextState);
        Tree.Node correctFinalNode =
            Tree.Node.wrap(Machine.Hash.unwrap(CORRECT_FINAL_STATE));
        Tree.Node incorrectStepNode =
            Tree.Node.wrap(Machine.Hash.unwrap(INCORRECT_STEP_STATE));
        Tree.Node incorrectFinalNode =
            Tree.Node.wrap(Machine.Hash.unwrap(INCORRECT_FINAL_STATE));
        Tree.Node correctCommitment = nextNode.join(correctFinalNode);
        Tree.Node incorrectCommitment =
            incorrectStepNode.join(incorrectFinalNode);

        _join(
            tournament,
            correctCommitment,
            CORRECT_FINAL_STATE,
            nextNode,
            correctFinalNode
        );
        _join(
            tournament,
            incorrectCommitment,
            INCORRECT_FINAL_STATE,
            incorrectStepNode,
            incorrectFinalNode
        );

        Match.Id memory matchId =
            Match.Id(correctCommitment, incorrectCommitment);
        tournament.sealLeafMatch(
            matchId,
            nextNode,
            correctFinalNode,
            Machine.Hash.wrap(beforeState),
            new bytes32[](0)
        );

        vm.expectCall(
            address(provider),
            abi.encodeCall(
                IDataProvider.provideMerkleRootOfInput, (0, expectedInput)
            ),
            1
        );
        tournament.winLeafMatch(matchId, nextNode, correctFinalNode, stepProof);

        ITournament.TournamentStandingView memory standing =
            tournament.tournamentStanding();
        assertEq(
            uint8(standing.standing),
            uint8(ITournament.TournamentStanding.AWAITING_CLOSURE)
        );
        assertTrue(standing.hasCandidate);
        assertTrue(standing.candidate.eq(correctCommitment));
    }

    function _inputOpeningVector()
        private
        returns (bytes32 beforeState, bytes32 nextState, bytes memory proof)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "lua";
        cmd[1] = "test/step/proofs.lua";
        cmd[2] = "0";
        cmd[3] = "1";

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory encoded = vm.ffi(cmd);
        return abi.decode(encoded, (bytes32, bytes32, bytes));
    }

    function _join(
        ITournament tournament,
        Tree.Node commitment,
        Machine.Hash finalState,
        Tree.Node left,
        Tree.Node right
    ) private {
        assertTrue(commitment.eq(left.join(right)));
        bytes32[] memory finalStateProof = new bytes32[](1);
        finalStateProof[0] = Tree.Node.unwrap(left);
        tournament.joinTournament{value: tournament.bondValue()}(
            finalState, finalStateProof, left, right
        );
    }
}
