// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MoneyBackHook, IPoolManager, PoolKey} from "../src/MoneyBackHook.sol";
import {MoneyBackRouter} from "../src/MoneyBackRouter.sol";
import {RoundPayout} from "../src/RoundPayout.sol";

interface VmAuxiliaries {
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Deploy the two contracts the installed univ4_hook manifest cannot express.
/// @dev Takes real post-launch addresses as arguments; never resolves invented placeholders.
///      The hook must already be deployed and initialized by the launch factory.
contract DeployAuxiliaries {
    VmAuxiliaries private constant vm = VmAuxiliaries(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant CHAIN_ID = 4663;
    address public constant PAYING_WALLET = 0x57797Cba5196A87959a0B8f1b8A42e5aeD721eac;

    error WrongChain();
    error MissingDeployment();
    error WrongManager();
    error WrongPayout();
    error WrongHook();
    error PoolNotInitialized();

    /// @notice Foundry entry point. Without --broadcast, forge script only simulates.
    function run(address manager, address deployedHook) external returns (RoundPayout payout, MoneyBackRouter router) {
        validate(manager, deployedHook);
        vm.startBroadcast();
        (payout, router) = _deploy(manager, deployedHook);
        vm.stopBroadcast();
    }

    /// @notice Same deployment logic without broadcast cheatcodes, exercised directly by tests.
    function deploy(address manager, address deployedHook)
        external
        returns (RoundPayout payout, MoneyBackRouter router)
    {
        validate(manager, deployedHook);
        return _deploy(manager, deployedHook);
    }

    function validate(address manager, address deployedHook) public view {
        if (block.chainid != CHAIN_ID) revert WrongChain();
        if (manager.code.length == 0 || deployedHook.code.length == 0) revert MissingDeployment();
        MoneyBackHook hook = MoneyBackHook(deployedHook);
        if (address(hook.poolManager()) != manager) revert WrongManager();
        if (hook.payout() != PAYING_WALLET) revert WrongPayout();
        if (uint160(deployedHook) & 0x3FFF != 0x20CC || hook.requiredFlags() != 0x20CC) revert WrongHook();
        if (hook.launchToken().code.length == 0) revert MissingDeployment();
        PoolKey memory key = hook.poolKey();
        if (hook.initializedAt() == 0 || address(key.hooks) != deployedHook) revert PoolNotInitialized();
    }

    function _deploy(address manager, address deployedHook)
        private
        returns (RoundPayout payout, MoneyBackRouter router)
    {
        payout = new RoundPayout(PAYING_WALLET);
        router = new MoneyBackRouter(IPoolManager(manager), deployedHook);
    }
}
