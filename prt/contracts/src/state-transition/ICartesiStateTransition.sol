// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IStateTransition} from "prt-contracts/IStateTransition.sol";
import {IVersionGetter} from "prt-contracts/IVersionGetter.sol";

interface ICartesiStateTransition is IStateTransition, IVersionGetter {}
