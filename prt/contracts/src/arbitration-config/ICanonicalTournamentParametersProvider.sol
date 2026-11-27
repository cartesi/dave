// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {IVersionGetter} from "prt-contracts/IVersionGetter.sol";
import {ITournamentParametersProvider} from "prt-contracts/arbitration-config/ITournamentParametersProvider.sol";

interface ICanonicalTournamentParametersProvider is
    ITournamentParametersProvider,
    IVersionGetter
{}
