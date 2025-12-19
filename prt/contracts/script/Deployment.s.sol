// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {BaseDeploymentScript} from "./BaseDeploymentScript.sol";

import {
    ArbitrationConstants
} from "src/arbitration-config/ArbitrationConstants.sol";
import {
    CanonicalTournamentParametersProvider
} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {
    CartesiStateTransition
} from "src/state-transition/CartesiStateTransition.sol";
import {
    CartesiStateTransition
} from "src/state-transition/CartesiStateTransition.sol";
import {
    CmioStateTransition
} from "src/state-transition/CmioStateTransition.sol";
import {
    RiscVStateTransition
} from "src/state-transition/RiscVStateTransition.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {
    MultiLevelTournamentFactory
} from "src/tournament/factories/MultiLevelTournamentFactory.sol";
import {Time} from "src/tournament/libs/Time.sol";

type Milliseconds is uint64;

using {divideMilliseconds as /} for Milliseconds global;

/// @notice Divide two amounts of time in milliseconds
/// @param a The dividend
/// @param b The divisor
/// @return c The quotient
function divideMilliseconds(Milliseconds a, Milliseconds b)
    pure
    returns (Milliseconds c)
{
    c = Milliseconds.wrap(Milliseconds.unwrap(a) / Milliseconds.unwrap(b));
}

type Seconds is uint64;

using {addSeconds as +} for Seconds global;
using {multiplySeconds as *} for Seconds global;

/// @notice Add two amounts of time in seconds.
/// @param a The augend
/// @param b The addend
/// @return aPlusB The sum
function addSeconds(Seconds a, Seconds b) pure returns (Seconds aPlusB) {
    aPlusB = Seconds.wrap(Seconds.unwrap(a) + Seconds.unwrap(b));
}

/// @notice Multiply two amounts of time in seconds.
/// @param a The first factor
/// @param b The second factor
/// @param aTimesB The product
function multiplySeconds(Seconds a, Seconds b) pure returns (Seconds aTimesB) {
    aTimesB = Seconds.wrap(Seconds.unwrap(a) * Seconds.unwrap(b));
}

library LibSeconds {
    /// @notice Convert seconds to milliseconds.
    /// @param secs An amount of time in seconds
    /// @return millisecs The same amount of time in milliseconds
    function toMilliseconds(Seconds secs)
        internal
        pure
        returns (Milliseconds millisecs)
    {
        millisecs = Milliseconds.wrap(Seconds.unwrap(secs) * 1000);
    }

    /// @notice Convert an amount of time in seconds into a number of blocks,
    /// based on the average block time of a given chain.
    /// @param secs An amount of time in seconds
    /// @param avgBlockTime The average block time in milliseconds
    /// @return d The amount of time in average number of blocks
    function toTimeDuration(Seconds secs, Milliseconds avgBlockTime)
        internal
        pure
        returns (Time.Duration d)
    {
        Milliseconds millisecs = toMilliseconds(secs);
        d = Time.Duration.wrap(Milliseconds.unwrap(millisecs / avgBlockTime));
    }
}

contract DeploymentScript is BaseDeploymentScript {
    using LibSeconds for Seconds;

    /// @notice Chain kind
    enum ChainKind {
        MAINNET, // live network with real assets
        TESTNET, // live network with dummy assets
        DEVNET // local network with dummy assets
    }

    /// @notice Chain information
    /// @param registered Whether the chain was registered or not
    /// @param kind The chain kind
    /// @param avgBlockTime The average block time in milliseconds
    struct ChainInfo {
        bool registered;
        ChainKind kind;
        Milliseconds avgBlockTime;
    }

    /// @notice Chain information.
    mapping(uint256 chainId => ChainInfo) _chainInfos;

    /// @notice Chain kind information
    /// @param registered Whether the chain kind was registered or not
    /// @param maxAllowance The maximum allowance
    struct ChainKindInfo {
        bool registered;
        Seconds maxAllowance;
    }

    /// @notice Chain kind information.
    mapping(ChainKind chainKind => ChainKindInfo) _chainKindInfos;

    /// @notice This error is raised when a chain is already registered
    /// and the script attempst to register it again.
    /// @param chainId The chain ID
    error ChainInfoAlreadyRegistered(uint256 chainId);

    /// @notice This error is raised whenever the script is run against a chain
    /// that has not been registered. If you wish to support this chain, please register
    /// the chain kind in the `_registerChains` function.
    /// @param chainId The chain ID
    error UnregisteredChain(uint256 chainId);

    /// @notice This error is raised when a chain kind is already registered
    /// and the script attempst to register it again.
    /// @param chainKind The chain kind
    error ChainKindAlreadyRegistered(ChainKind chainKind);

    /// @notice This error is raised whenever the script is run against a chain
    /// whose kind has not been registered. If you wish to support this chain, please register
    /// the chain kind in the `_registerChainKinds` function.
    /// @param chainKind The chain kind
    error UnregisteredChainKind(ChainKind chainKind);

    /// @notice Deploy the PRT contracts.
    /// @dev Serializes deployed contract addresses to `deployments.json`.
    function run() external {
        _registerChains();
        _registerChainKinds();

        Time.Duration matchEffort = _getMatchEffort();
        Time.Duration maxAllowance = _getMaxAllowance();

        vmSafe.startBroadcast();

        address riscVStateTransition = _storeDeployment(
            type(RiscVStateTransition).name,
            _create2(type(RiscVStateTransition).creationCode, abi.encode())
        );

        address cmioStateTransition = _storeDeployment(
            type(CmioStateTransition).name,
            _create2(type(CmioStateTransition).creationCode, abi.encode())
        );

        address cartesiStateTransition = _storeDeployment(
            type(CartesiStateTransition).name,
            _create2(
                type(CartesiStateTransition).creationCode,
                abi.encode(riscVStateTransition, cmioStateTransition)
            )
        );

        address tournamentImpl = _storeDeployment(
            type(Tournament).name,
            _create2(type(Tournament).creationCode, abi.encode())
        );

        address canonicalTournamentParametersProvider = _storeDeployment(
            type(CanonicalTournamentParametersProvider).name,
            _create2(
                type(CanonicalTournamentParametersProvider).creationCode,
                abi.encode(matchEffort, maxAllowance)
            )
        );

        _storeDeployment(
            type(MultiLevelTournamentFactory).name,
            _create2(
                type(MultiLevelTournamentFactory).creationCode,
                abi.encode(
                    tournamentImpl,
                    canonicalTournamentParametersProvider,
                    cartesiStateTransition
                )
            )
        );

        vmSafe.stopBroadcast();
    }

    /// @notice Register all supported chains.
    function _registerChains() internal {
        _registerChain(1, ChainKind.MAINNET, Milliseconds.wrap(12000));
        _registerChain(10, ChainKind.MAINNET, Milliseconds.wrap(2000));
        _registerChain(8453, ChainKind.MAINNET, Milliseconds.wrap(2000));
        _registerChain(13370, ChainKind.DEVNET, Milliseconds.wrap(12000));
        _registerChain(31337, ChainKind.DEVNET, Milliseconds.wrap(12000));
        _registerChain(42161, ChainKind.MAINNET, Milliseconds.wrap(2500));
        _registerChain(84532, ChainKind.TESTNET, Milliseconds.wrap(2000));
        _registerChain(421614, ChainKind.TESTNET, Milliseconds.wrap(2500));
        _registerChain(11155111, ChainKind.TESTNET, Milliseconds.wrap(12000));
        _registerChain(11155420, ChainKind.TESTNET, Milliseconds.wrap(2000));
    }

    /// @notice Register information about a particular chain.
    /// @param chainId The chain ID
    /// @param kind The chain kind
    /// @param avgBlockTime The average block time in milliseconds
    function _registerChain(
        uint256 chainId,
        ChainKind kind,
        Milliseconds avgBlockTime
    ) internal {
        ChainInfo storage chainInfo = _chainInfos[chainId];
        require(!chainInfo.registered, ChainInfoAlreadyRegistered(chainId));
        chainInfo.kind = kind;
        chainInfo.avgBlockTime = avgBlockTime;
        chainInfo.registered = true;
    }

    /// @notice Get information about the current chain.
    /// @dev Should be called after `_registerChains`.
    function _getCurrentChainInfo()
        internal
        view
        returns (ChainInfo memory chainInfo)
    {
        uint256 chainId = block.chainid;
        chainInfo = _chainInfos[chainId];
        require(chainInfo.registered, UnregisteredChain(chainId));
    }

    /// @notice Register all supported chain kinds.
    function _registerChainKinds() internal {
        _registerChainKind(ChainKind.MAINNET, Seconds.wrap(1 weeks + 1 hours));
        _registerChainKind(ChainKind.TESTNET, Seconds.wrap(9 hours));
        _registerChainKind(ChainKind.DEVNET, Seconds.wrap(1 hours));
    }

    /// @notice Register a chain kind.
    /// @param kind The chain kind
    /// @param maxAllowance The maximum allowance in the chain kind.
    function _registerChainKind(ChainKind kind, Seconds maxAllowance) internal {
        ChainKindInfo storage chainKindInfo = _chainKindInfos[kind];
        require(!chainKindInfo.registered, ChainKindAlreadyRegistered(kind));
        chainKindInfo.maxAllowance = maxAllowance;
        chainKindInfo.registered = true;
    }

    /// @notice Get information about the current chain kind.
    /// @dev Should be called after `_registerChains` and `_registerChainKinds`.
    function _getCurrentChainKindInfo()
        internal
        view
        returns (ChainKindInfo memory chainKindInfo)
    {
        ChainInfo memory chainInfo = _getCurrentChainInfo();
        ChainKind kind = chainInfo.kind;
        chainKindInfo = _chainKindInfos[kind];
        require(chainKindInfo.registered, UnregisteredChainKind(kind));
    }

    /// @notice Calculate the match effort in avg number of blocks
    /// based on the arbitration constants and the current chain.
    /// @return matchEffort The match effort in avg number of blocks
    function _getMatchEffort()
        internal
        view
        returns (Time.Duration matchEffort)
    {
        ChainInfo memory chainInfo = _getCurrentChainInfo();
        Milliseconds avgBlockTime = chainInfo.avgBlockTime;
        return _getMatchEffortInSeconds().toTimeDuration(avgBlockTime);
    }

    /// @notice Calculate the match effort in seconds based on the arbitration constants.
    /// @return matchEffortInSeconds The match effort in seconds
    function _getMatchEffortInSeconds()
        internal
        pure
        returns (Seconds matchEffortInSeconds)
    {
        return Seconds.wrap(5 minutes * _sum(_getTournamentHeights()));
    }

    /// @notice Get the heights of each tournament level.
    /// @return heights The height of each tournament level, from top to bottom.
    function _getTournamentHeights()
        internal
        pure
        returns (uint64[] memory heights)
    {
        heights = new uint64[](ArbitrationConstants.LEVELS);
        for (uint64 level; level < heights.length; ++level) {
            heights[level] = ArbitrationConstants.height(level);
        }
    }

    /// @notice Sum up the elements of an array.
    /// @param array An array of uint64 values
    /// @return arraySum The sum of the array elements
    function _sum(uint64[] memory array)
        internal
        pure
        returns (uint64 arraySum)
    {
        for (uint256 i; i < array.length; ++i) {
            arraySum += array[i];
        }
    }

    /// @notice Get the maximum allowance in avg number of blocks
    /// based on the current chain and its kind.
    /// @return maxAllowance The maximum allowance in avg number of blocks
    function _getMaxAllowance()
        internal
        view
        returns (Time.Duration maxAllowance)
    {
        ChainInfo memory chainInfo = _getCurrentChainInfo();
        Milliseconds avgBlockTime = chainInfo.avgBlockTime;
        return _getMaxAllowanceInSeconds().toTimeDuration(avgBlockTime);
    }

    /// @notice Get the maximum allowance in seconds based on the current chain kind.
    /// @return maxAllowanceInSeconds The maximum allowance in seconds
    function _getMaxAllowanceInSeconds()
        internal
        view
        returns (Seconds maxAllowanceInSeconds)
    {
        return _getCurrentChainKindInfo().maxAllowance;
    }
}
