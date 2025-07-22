// Copyright 2023 Cartesi Pte. Ltd.

// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the
// License at http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "forge-std-1.9.6/src/Test.sol";

import "./Util.sol";
import "src/state-transition/RiscZeroStateTransition.sol";

pragma solidity ^0.8.0;

contract StateTransitionRiscZeroFfiTest is Util, Test {
    CartesiStateTransitionWithRiscZero stateTransition;

    address constant riscZeroVerifierAddress = 0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187;
    bytes32 constant riscZeroImageId = 0xfcd5566bd7907f09bb2d620c276309f8cef3cf0fc733b041be1eb9e5df4e727d;

    string PROVER_SCRIPT_PATH = "test/step/zk_proof.py";
    string CM_WRAPPER_SCRIPT_PATH = "test/step/cm_wrapper.py";
    string STEP_LOG_PATH = "test/cache/test-step.log";

    function split(string memory _str, string memory _delim)
        internal
        pure
        returns (string[] memory)
    {
        bytes memory str = bytes(_str);
        bytes memory delim = bytes(_delim);
        require(delim.length > 0, "delimiter cannot be empty");

        uint256 parts = 1;
        for (uint256 i; i + delim.length <= str.length; i++) {
            bool hit;
            for (uint256 j; j < delim.length; j++)
                if (str[i + j] != delim[j]) { hit = false; break; } else hit = true;
            if (hit) parts++;
        }

        string[] memory out = new string[](parts);
        uint256 last = 0;
        uint256 idx = 0;
        for (uint256 i; i + delim.length <= str.length; i++) {
            bool hit;
            for (uint256 j; j < delim.length; j++)
                if (str[i + j] != delim[j]) { hit = false; break; } else hit = true;
            if (hit) {
                out[idx++] = substring(_str, last, i);
                last = i + delim.length;
                i   += delim.length - 1;
            }
        }
        out[idx] = substring(_str, last, str.length);
        return out;
    }

    function substring(string memory str, uint256 start, uint256 finish)
        internal
        pure
        returns (string memory)
    {
        bytes memory s = bytes(str);
        bytes memory r = new bytes(finish - start);
        for (uint256 i = start; i < finish; i++) r[i - start] = s[i];
        return string(r);
    }

    constructor() {
        stateTransition = new CartesiStateTransitionWithRiscZero(
            riscZeroVerifierAddress,
            riscZeroImageId
        );
    }

    function generateRiscZeroProof(
        bytes32 startHash,
        bytes32 endHash,
        uint256 numCycles,
        string memory stepLogFile
    ) private returns (bytes memory proof) {
        string[] memory cmd = new string[](5);
        cmd[0] = PROVER_SCRIPT_PATH;
        cmd[1] = vm.toString(startHash);
        cmd[2] = vm.toString(endHash);
        cmd[3] = vm.toString(numCycles);
        cmd[4] = stepLogFile;

        bytes memory res = vm.ffi(cmd);
        (bytes32 status, bytes32 message, bytes memory payload) =
            abi.decode(res, (bytes32, bytes32, bytes));

        if (status != 0) {
            revert(
                string(
                    abi.encodePacked("FFI error (prover): ", vm.toString(message))
                )
            );
        }

        return payload;
    }

    function runCartesiMachineStep(
        uint256 numCycles
    ) private returns (bytes32 startHash, bytes32 endHash) {
        // remove any previous step log so cartesi-machine won't complain
        string[] memory rm_cmd = new string[](3);
        rm_cmd[0] = "rm";
        rm_cmd[1] = "-f";
        rm_cmd[2] = STEP_LOG_PATH;
        vm.ffi(rm_cmd);

        // construct the command to run the Cartesi Machine
        string[] memory cm_cmd = new string[](4);
        cm_cmd[0] = "python3";
        cm_cmd[1] = CM_WRAPPER_SCRIPT_PATH;
        cm_cmd[2] = string.concat("--log-step=", vm.toString(numCycles), ",", STEP_LOG_PATH);
        cm_cmd[3] = "--max-mcycle=0";

        bytes memory machineOutputBytes = vm.ffi(cm_cmd);

        // parse the output to extract the hashes
        // the expected output format is:
        //  Logging step of <numCycles> cycles to ...
        //  0: <start_hash>
        //  <numCycles>: <end_hash>
        string[] memory lines = split(string(machineOutputBytes), "\n");
        require(lines.length >= 3, "Unexpected output from cartesi-machine");

        string[] memory startLineParts = split(lines[1], ": ");
        require(startLineParts.length == 2, "Could not parse start hash line");
        startHash = vm.parseBytes32(string.concat("0x", startLineParts[1]));

        string[] memory endLineParts = split(lines[2], ": ");
        endHash = vm.parseBytes32(string.concat("0x", endLineParts[1]));
    }

    function assertStf(
        bytes32 startHash,
        bytes32 endHash,
        uint256 numCycles,
        string memory stepLogFile
    ) private {
        bytes memory proof = generateRiscZeroProof(startHash, endHash, numCycles, stepLogFile);
        stateTransition.transitionState(startHash, 0, proof, IDataProvider(address(0)));
        // the transitionState function will revert if the proof is invalid
    }

    function testStateTransitionZkSingleCycle() public {
        uint256 numCycles = 1;

        // run the Cartesi Machine to generate the step.log and get the corresponding hashes
        (bytes32 startHash, bytes32 endHash) = runCartesiMachineStep(numCycles);

        console.log("CM start hash:");
        console.logBytes32(startHash);

        console.log("CM end hash:");
        console.logBytes32(endHash);

        // run the state transition with the dynamically generated data
        // it will revert if the proof is invalid
        assertStf(startHash, endHash, numCycles, STEP_LOG_PATH);
    }
}
