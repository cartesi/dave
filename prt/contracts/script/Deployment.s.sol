// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.8;

import {BaseDeploymentScript} from "./BaseDeploymentScript.sol";

import {ArbitrationConstants} from "src/arbitration-config/ArbitrationConstants.sol";
import {CanonicalTournamentParametersProvider} from "src/arbitration-config/CanonicalTournamentParametersProvider.sol";
import {ClockBudgets} from "src/arbitration-config/ClockBudgets.sol";
import {CartesiStateTransition} from "src/state-transition/CartesiStateTransition.sol";
import {Tournament} from "src/tournament/Tournament.sol";
import {MultiLevelTournamentFactory} from "src/tournament/factories/MultiLevelTournamentFactory.sol";

/// @notice An amount of time in milliseconds.
type Milliseconds is uint64;

/// @notice An amount of time in seconds.
type Seconds is uint64;

contract DeploymentScript is BaseDeploymentScript {
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
    /// @param censorshipBudget The censorship a correct commitment survives
    struct ChainKindInfo {
        bool registered;
        Seconds censorshipBudget;
    }

    /// @notice Chain kind information.
    mapping(ChainKind chainKind => ChainKindInfo) _chainKindInfos;

    /// @notice This error is raised when a chain is already registered
    /// and the script attempst to register it again.
    /// @param chainId The chain ID
    error ChainInfoAlreadyRegistered(uint256 chainId);

    /// @notice This error is raised whenever the script is run against a chain
    /// that has not been registered. Register the chain in `_registerChains`
    /// before deploying to it.
    /// @param chainId The chain ID
    error UnregisteredChain(uint256 chainId);

    /// @notice This error is raised when a chain kind is already registered
    /// and the script attempst to register it again.
    /// @param chainKind The chain kind
    error ChainKindAlreadyRegistered(ChainKind chainKind);

    /// @notice This error is raised whenever the script is run against a chain
    /// whose kind has not been registered. Register the chain kind in
    /// `_registerChainKinds` before deploying to it.
    /// @param chainKind The chain kind
    error UnregisteredChainKind(ChainKind chainKind);

    /// @notice Deploy the PRT contracts.
    /// @dev Serializes deployed contract addresses to both
    /// `deployments/<chain-id>/<contract-name>.txt` and
    /// `deployments/<chain-id>/<contract-name>.json` (deprecated).
    function run() external {
        _registerChains();
        _registerChainKinds();

        bytes memory providerArguments = _canonicalProviderArguments();

        vmSafe.startBroadcast();

        address cartesiStateTransition = _storeDeployment(
            type(CartesiStateTransition).name,
            _create2(type(CartesiStateTransition).creationCode, abi.encode())
        );

        address tournamentImpl = _storeDeployment(
            type(Tournament).name,
            _create2(type(Tournament).creationCode, abi.encode())
        );

        address canonicalTournamentParametersProvider = _storeDeployment(
            type(CanonicalTournamentParametersProvider).name,
            _create2(
                type(CanonicalTournamentParametersProvider).creationCode,
                providerArguments
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

    /// @notice Register configured deployment targets.
    /// @dev Registration is not a protocol-support designation. Ethereum is
    /// the supported target; other entries are experimental until their time
    /// coordinate and conversion are validated.
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
    /// @dev Devnets tolerate no censorship: their clocks cover only the
    /// honest path (every action within one inclusion, every build within the
    /// commitment budget), which keeps local disputes short.
    function _registerChainKinds() internal {
        _registerChainKind(ChainKind.MAINNET, Seconds.wrap(1 weeks));
        _registerChainKind(ChainKind.TESTNET, Seconds.wrap(8 hours));
        _registerChainKind(ChainKind.DEVNET, Seconds.wrap(0));
    }

    /// @notice Register a chain kind.
    /// @param kind The chain kind
    /// @param censorshipBudget The censorship a correct commitment survives
    function _registerChainKind(ChainKind kind, Seconds censorshipBudget)
        internal
    {
        ChainKindInfo storage chainKindInfo = _chainKindInfos[kind];
        require(!chainKindInfo.registered, ChainKindAlreadyRegistered(kind));
        chainKindInfo.censorshipBudget = censorshipBudget;
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

    /// @notice The canonical provider's constructor arguments for the current
    /// chain; the provider takes its commitment budget from the geometry.
    /// @dev Should be called after `_registerChains` and `_registerChainKinds`.
    function _canonicalProviderArguments()
        internal
        view
        returns (bytes memory)
    {
        ClockBudgets.Model memory clocks = _getClockModel(
            Seconds.wrap(ArbitrationConstants.COMMITMENT_BUDGET)
        );
        return abi.encode(
            clocks.blockMilliseconds,
            clocks.censorshipSeconds,
            clocks.inclusionSeconds
        );
    }

    /// @notice The time for one action to land, on every chain.
    function _getInclusionBudget() internal pure returns (Seconds) {
        return Seconds.wrap(5 minutes);
    }

    /// @notice The clock model for the current chain and a geometry's
    /// commitment budget; providers derive their block budgets from it.
    /// @dev Should be called after `_registerChains` and `_registerChainKinds`.
    function _getClockModel(Seconds commitmentBudget)
        internal
        view
        returns (ClockBudgets.Model memory)
    {
        return ClockBudgets.Model({
            blockMilliseconds: Milliseconds.unwrap(
                _getCurrentChainInfo().avgBlockTime
            ),
            censorshipSeconds: Seconds.unwrap(
                _getCurrentChainKindInfo().censorshipBudget
            ),
            inclusionSeconds: Seconds.unwrap(_getInclusionBudget()),
            commitmentSeconds: Seconds.unwrap(commitmentBudget)
        });
    }
}
