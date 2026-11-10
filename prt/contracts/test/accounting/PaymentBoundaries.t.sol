// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

/// @dev Rejects value until told to accept it.
contract ToggleReceiver {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    receive() external payable {
        require(accept);
    }
}

/// @dev Forwards a call under a gas limit and, as the refund recipient,
/// burns whatever it is forwarded unless it sees at least 45,000 gas.
contract GasHungryCaller {
    uint256 public seen;

    function go(address target, bytes calldata data, uint256 gasLimit)
        external
        returns (bool ok)
    {
        (ok,) = target.call{gas: gasLimit}(data);
    }

    receive() external payable {
        uint256 g = gasleft();
        if (g < 45_000) {
            while (true) {}
        }
        seen = g;
    }
}

/// @dev Boundaries of the two payment paths and of value intake on the
/// production Tournament, beside the callback behavior RefundCallbacks.t.sol
/// owns: the transient lock is released on every return path of
/// `tryRecoveringBond`, an action given too little gas reverts rather than
/// completing with a starved refund, and a clone takes value only through a
/// join. Deterministic pins on the small one-level fixture; they establish
/// nothing about receipt gas or about recipients other than the two above.
contract PaymentBoundariesTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant ALLOWANCE = 200;

    /// @dev The calls share one transaction, so a lock leaked by an early
    /// `return` would revert the next call with `ReentrancyDetected`.
    function testRecoveryReleasesLockOnEveryReturnPath() public {
        vm.roll(100);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        ToggleReceiver claimer = new ToggleReceiver();
        vm.deal(address(claimer), 10 ether);
        join(t, seededTree(bytes32(uint256(1)), 3), address(claimer));
        rollTo(closureOf(t));
        uint256 bond = t.bondValue();

        assertFalse(t.tryRecoveringBond()); // rejected payment
        assertFalse(t.tryRecoveringBond()); // the lock was released
        assertEq(address(t).balance, bond);

        claimer.setAccept(true);
        uint256 before = address(claimer).balance;
        assertTrue(t.tryRecoveringBond()); // full path
        assertEq(address(claimer).balance - before, bond);
        assertTrue(t.tryRecoveringBond()); // already recovered
        assertTrue(t.tryRecoveringBond()); // the lock was released again
        assertEq(address(claimer).balance - before, bond);
    }

    /// @dev Refuted: a low gas limit makes an action complete while the
    /// 63/64 rule starves its refund callback. The recipient is the caller.
    /// Over a sweep of the gas given to one advance, the action either
    /// reverts and pays nothing, or completes with the refund paid and the
    /// recipient given its full ceiling.
    function testRefutedLowGasLimitStarvesRefund() public {
        vm.roll(100);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        SmallFullTree.Data memory one = seededTree(bytes32(uint256(1)), 3);
        SmallFullTree.Data memory two = seededTree(bytes32(uint256(2)), 3);
        join(t, one, HONEST);
        join(t, two, SYBIL);
        (Tree.Node left, Tree.Node right) = one.children(3, 0);
        uint256 selected = left.eq(two.node(2, 0)) ? 1 : 0;
        (Tree.Node nl, Tree.Node nr) = one.children(2, selected);
        bytes memory data = abi.encodeCall(
            ITournament.advanceMatch, (matchId(one, two), left, right, nl, nr)
        );
        GasHungryCaller caller = new GasHungryCaller();

        uint256 successes;
        uint256 firstSuccessGas;
        uint256 minSeen = type(uint256).max;
        uint256 snap = vm.snapshotState();
        for (uint256 g = 60_000; g <= 260_000; g += 250) {
            bool ok = caller.go{gas: g + 20_000}(address(t), data, g);
            if (ok) {
                ++successes;
                if (firstSuccessGas == 0) {
                    firstSuccessGas = g;
                }
                uint256 seen = caller.seen();
                assertGt(address(caller).balance, 0, "refund paid");
                assertGe(seen, 45_000, "recipient was not starved");
                if (seen < minSeen) {
                    minSeen = seen;
                }
            } else {
                assertEq(address(caller).balance, 0);
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 0);
        emit log_named_uint("first gas limit that lands", firstSuccessGas);
        emit log_named_uint("least gas a paid recipient saw", minSeen);
    }

    function testCloneRejectsPlainEther() public {
        vm.roll(100);
        InspectableTournament t = newRoot(singleLevelFactory(G, ALLOWANCE));
        (bool ok,) = address(t).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(t).balance, 0);
    }
}
