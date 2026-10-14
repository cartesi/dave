// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Test} from "forge-std-1.9.6/src/Test.sol";
import {console2} from "forge-std-1.9.6/src/console2.sol";

import {HonestSurvivalHandler} from "./HonestSurvivalInvariant.t.sol";

/// @dev A deterministic sample of the R19 search: the handler driven by a
/// keccak stream with the invariant checked after every move, reporting the
/// applied and discarded count per adversary move and how deep the schedule
/// got (children the honest side entered, root finishes). Evidence for the
/// search's reach, not a property.
contract HonestSurvivalSampleTest is Test {
    string[8] names = [
        "joinRootSybil",
        "joinChildSybil",
        "sybilRespond",
        "claimTimeout",
        "proveSybil",
        "settleChild",
        "actForHonest",
        "elapse"
    ];

    function _drive(HonestSurvivalHandler h, uint256 seedIn, uint256 steps)
        internal
    {
        uint256 r = seedIn;
        for (uint256 i; i < steps; ++i) {
            r = uint256(keccak256(abi.encode(r)));
            uint8 sel = uint8(r % 8);
            uint8 delta = uint8(r >> 8);
            bool hf = (r >> 16) & 1 == 1;
            uint256 e = r >> 24;
            uint8 a = uint8(r >> 32);
            uint8 b = uint8(r >> 40);
            uint8 c = uint8(r >> 48);
            bool late = (r >> 56) & 1 == 1;
            if (sel == 0) {
                h.joinRootSybil(delta, hf, e, a, b, c, late);
            } else if (sel == 1) {
                h.joinChildSybil(delta, hf, e, a, b & 1 == 1, b, c, late);
            } else if (sel == 2) {
                h.sybilRespond(delta, hf, e, a, b, late, c);
            } else if (sel == 3) {
                h.claimTimeout(delta, hf, e, a, b);
            } else if (sel == 4) {
                h.proveSybil(delta, hf, e, a, b, c & 1 == 1);
            } else if (sel == 5) {
                h.settleChild(delta, hf, e, a, late);
            } else if (sel == 6) {
                h.actForHonest(delta, hf, e);
            } else {
                h.elapse(delta, hf, e);
            }
            h.checkHonestSurvives();
            h.checkClocksCover();
        }
    }

    function _report(HonestSurvivalHandler h) internal view {
        for (uint256 i; i < 8; ++i) {
            console2.log(
                names[i], h.appliedBy(names[i]), h.discardedBy(names[i])
            );
        }
        console2.log(
            "honestActions",
            h.honestActions(),
            "tournaments",
            h.tournamentCount()
        );
        console2.log(
            "childrenWithHonest",
            h.childrenWithHonest(),
            "rootFinishes",
            h.rootFinishes()
        );
        console2.log(
            "censorshipUsed", h.censorshipUsed(), "block", vm.getBlockNumber()
        );
    }

    function testSearchSampleDistribution() public {
        for (uint256 s = 1; s <= 6; ++s) {
            uint64 c = s <= 2 ? 0 : s <= 4 ? 2 : 5;
            HonestSurvivalHandler h =
                new HonestSurvivalHandler(3, 6, c, s % 2 == 0);
            _drive(h, s, 300);
            console2.log("--- seed", s, "C", c);
            _report(h);
        }
    }
}
