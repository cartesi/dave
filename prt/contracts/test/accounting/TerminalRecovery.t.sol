// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.17;

import {ITournament} from "src/ITournament.sol";
import {Bond} from "src/tournament/libs/Bond.sol";
import {Time} from "src/tournament/libs/Time.sol";
import {Tree} from "src/types/Tree.sol";

import {InspectableTournament} from "test/fixtures/InspectableTournament.sol";
import {SmallFullTree} from "test/fixtures/SmallFullTree.sol";

import {TournamentDriver} from "test/fixtures/TournamentDriver.sol";

contract Rejecter {
    receive() external payable {
        revert();
    }
}

contract Acceptor {
    event Got(uint256 v);

    receive() external payable {
        emit Got(msg.value);
    }
}

contract StorageAcceptor {
    uint256 public total;

    receive() external payable {
        total += msg.value;
    }
}

contract SelfDestructSender {
    constructor() payable {}

    function blast(address payable to) external {
        selfdestruct(to);
    }
}

contract BouncingReceiver {
    SelfDestructSender public bomb;
    address public target;

    function arm(SelfDestructSender b, address t) external {
        bomb = b;
        target = t;
    }

    receive() external payable {
        if (address(bomb) != address(0)) {
            bomb.blast(payable(target));
        }
    }
}

/// Scratch probe for the terminal-recovery dimension. Not an exploit.
contract TerminalRecoveryTest is TournamentDriver {
    using SmallFullTree for SmallFullTree.Data;
    using Tree for Tree.Node;

    uint64 constant G = 5;
    uint64 constant T = 20;
    uint64 constant ALLOWANCE = 200;

    struct Dispute {
        InspectableTournament root;
        InspectableTournament child;
        SmallFullTree.Data hRoot;
        SmallFullTree.Data sRoot;
        SmallFullTree.Data hChild;
        SmallFullTree.Data sChild;
    }

    function _toChildFinish(address honestChildClaimer)
        internal
        returns (Dispute memory d)
    {
        vm.roll(100);
        d.root = newRoot(twoLevelFactory(G, T, ALLOWANCE));
        Tree.Node[] memory honest = fineLeaves(1);
        Tree.Node[] memory sybil = fineLeaves(1, 10, 2);
        d.hRoot = rootTreeOf(honest);
        d.sRoot = rootTreeOf(sybil);
        join(d.root, d.hRoot, HONEST);
        join(d.root, d.sRoot, SYBIL);
        advanceToSeal(d.root, d.hRoot, d.sRoot);
        uint256 segment;
        (d.child, segment) = sealInner(d.root, d.hRoot, d.sRoot);
        d.hChild = childTreeOf(honest, segment);
        d.sChild = childTreeOf(sybil, segment);
        rollBy(T + 1);
        join(d.child, d.sChild, SYBIL);
        vm.deal(honestChildClaimer, 10 ether);
        join(d.child, d.hChild, honestChildClaimer);
        advanceToSeal(d.child, d.sChild, d.hChild);
        uint256 divergence = sealLeaf(d.child, d.sChild, d.hChild);
        prove(d.child, d.sChild, d.hChild, d.hChild, divergence);
        rollTo(closureOf(d.child));
    }

    function testChildRecoveryBeforePropagation() public {
        Dispute memory d = _toChildFinish(HONEST);
        ITournament.InnerResultView memory before = d.child.innerResult();
        uint256 bond = d.child.bondValue();
        uint256 hb = HONEST.balance;
        uint256 childBal = address(d.child).balance;
        assertTrue(d.child.tryRecoveringBond());
        uint256 paid = HONEST.balance - hb;
        assertGe(paid, bond);
        assertEq(paid, bond + (childBal - bond) / 10);
        ITournament.InnerResultView memory afterR = d.child.innerResult();
        assertEq(uint8(afterR.disposition), uint8(before.disposition));
        assertTrue(afterR.parentCommitment.eq(before.parentCommitment));
        assertEq(
            uint64(Time_unwrap(afterR.pausedAllowance)),
            uint64(Time_unwrap(before.pausedAllowance))
        );
        propagate(d.root, d.child, d.hRoot);
        assertTrue(dangling(d.root).eq(d.hRoot.root()));
        // Child recovery is a no-op now.
        assertTrue(d.child.tryRecoveringBond());
        rollTo(closureOf(d.root));
        uint256 rb = d.root.bondValue();
        uint256 h2 = HONEST.balance;
        assertTrue(d.root.tryRecoveringBond());
        assertGe(HONEST.balance - h2, rb);
        emit log_named_uint("root paid", HONEST.balance - h2);
        emit log_named_uint("root bond", rb);
    }

    function testChildRecoveryAfterPropagation() public {
        Dispute memory d = _toChildFinish(HONEST);
        propagate(d.root, d.child, d.hRoot);
        uint256 bond = d.child.bondValue();
        uint256 hb = HONEST.balance;
        assertTrue(d.child.tryRecoveringBond());
        assertGe(HONEST.balance - hb, bond);
        (ITournament.BondDisposition disp,,) = d.child.bondRecovery();
        assertEq(uint8(disp), uint8(ITournament.BondDisposition.RECOVERED));
    }

    function testExpiredChildWinnerStillRecovers() public {
        Dispute memory d = _toChildFinish(HONEST);
        // Let the carryover window lapse; the parent eliminates both.
        ITournament.TournamentStandingView memory s =
            d.child.tournamentStanding();
        emit log_named_uint("standing", uint8(s.standing));
        emit log_named_uint("expiresAt", Time_unwrapI(s.winnerExpiresAt));
        emit log_named_uint("now", block.number);
        rollTo(uint256(Time_unwrapI(s.winnerExpiresAt)));
        eliminateChild(d.root, d.child);
        assertEq(liveMatches(d.root), 0);
        uint256 hb = HONEST.balance;
        assertTrue(d.child.tryRecoveringBond());
        assertGe(HONEST.balance - hb, d.child.bondValue());
        if (closureOf(d.root) > block.number) {
            rollTo(closureOf(d.root));
        }
        vm.expectRevert(ITournament.NoWinner.selector);
        d.root.tryRecoveringBond();
    }

    function test7702DelegatedClaimerRetry() public {
        uint256 pk = 0xA11CE7702;
        address eoa = vm.addr(pk);
        Rejecter rej = new Rejecter();
        Acceptor acc = new Acceptor();
        Dispute memory d = _toChildFinish(eoa);

        vm.signAndAttachDelegation(address(rej), pk);
        assertFalse(d.child.tryRecoveringBond());
        assertEq(d.child.observedClaimer(d.hChild.root()), eoa);
        uint256 bal = address(d.child).balance;
        assertGt(bal, 0);

        vm.signAndAttachDelegation(address(acc), pk);
        uint256 eb = eoa.balance;
        assertTrue(d.child.tryRecoveringBond());
        assertGe(eoa.balance - eb, d.child.bondValue());
        assertEq(address(d.child).balance, 0);
    }

    function testUnderGassedRecoveryPreservesState() public {
        StorageAcceptor acc = new StorageAcceptor();
        Dispute memory d = _toChildFinish(address(acc));
        uint256 bal = address(d.child).balance;
        bool sawFalse;
        for (uint256 g = 20_000; g < 80_000 && !sawFalse; g += 500) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(d.child).call{gas: g}(
                abi.encodeCall(ITournament.tryRecoveringBond, ())
            );
            if (ok && !abi.decode(ret, (bool))) {
                sawFalse = true;
                emit log_named_uint("false at gas", g);
                assertEq(address(d.child).balance, bal);
                assertEq(d.child.observedClaimer(d.hChild.root()), address(acc));
            }
            vm.revertToState(snap);
        }
        assertTrue(sawFalse);
        assertTrue(d.child.tryRecoveringBond());
    }

    function testForcedEthDuringCallbackIsBurned() public {
        BouncingReceiver br = new BouncingReceiver();
        Dispute memory d = _toChildFinish(address(br));
        SelfDestructSender bomb = new SelfDestructSender{value: 1 ether}();
        br.arm(bomb, address(d.child));
        uint256 bal = address(d.child).balance;
        uint256 bond = d.child.bondValue();
        uint256 burned0 = address(0).balance;
        uint256 br0 = address(br).balance;
        assertTrue(d.child.tryRecoveringBond());
        assertEq(address(br).balance - br0, bond + (bal - bond) / 10);
        assertEq(address(d.child).balance, 0);
        assertEq(
            address(0).balance - burned0,
            bal - (bond + (bal - bond) / 10) + 1 ether
        );
    }

    function Time_unwrap(Time.Duration x) internal pure returns (uint64) {
        return Time.Duration.unwrap(x);
    }

    function Time_unwrapI(Time.Instant x) internal pure returns (uint64) {
        return Time.Instant.unwrap(x);
    }
}
