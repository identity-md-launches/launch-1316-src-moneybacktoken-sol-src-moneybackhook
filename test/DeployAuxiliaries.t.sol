// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployAuxiliaries} from "../script/DeployAuxiliaries.s.sol";
import {MoneyBackRouter} from "../src/MoneyBackRouter.sol";
import {MoneyBackHook} from "../src/MoneyBackHook.sol";
import {RoundPayout} from "../src/RoundPayout.sol";
import {HookFixture, EXPECTED_FLAGS} from "./MoneyBackHook.t.sol";

interface VmAuxTest {
    function chainId(uint256) external;
}

contract DeployAuxiliariesTest is HookFixture {
    VmAuxTest constant chainVm = VmAuxTest(address(uint160(uint256(keccak256("hevm cheat code")))));
    DeployAuxiliaries deployer;

    function setUp() public {
        chainVm.chainId(4663);
        _setUpPool(true);
        deployer = new DeployAuxiliaries();
        hook = _deployHook(address(pm), address(token), deployer.PAYING_WALLET(), EXPECTED_FLAGS);
        key = _makeKey(true, address(hook));
        pm.initialize(key, 1 << 96);
    }

    function test_deploysBothAuxiliariesWithPayingWalletOwner() public {
        vm.prank(address(0xABC)); // caller and deployment helper must not become the owner
        (RoundPayout payout, MoneyBackRouter router) = deployer.deploy(address(pm), address(hook));
        assertEq(payout.owner(), deployer.PAYING_WALLET(), "round owner");
        assertEq(address(router.poolManager()), address(pm), "manager");
        assertEq(address(router.hook()), address(hook), "actual mined hook");
        assertEq(router.token(), address(token), "launch token");
        assertEq(hook.payout(), deployer.PAYING_WALLET(), "fees still go to wallet");
        assertEq(token.balanceOf(address(payout)), 0, "no launch allocation");
        assertEq(token.balanceOf(address(router)), 0, "no launch allocation");
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, address(this)));
        payout.pause();
        vm.prank(deployer.PAYING_WALLET());
        payout.pause();
        assertTrue(payout.paused(), "only owner controls rounds");
    }

    function test_wrongChainRefused() public {
        chainVm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployAuxiliaries.WrongChain.selector));
        deployer.deploy(address(pm), address(hook));
    }

    function test_unresolvedAddressesRefused() public {
        vm.expectRevert(abi.encodeWithSelector(DeployAuxiliaries.MissingDeployment.selector));
        deployer.deploy(address(pm), address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployAuxiliaries.MissingDeployment.selector));
        deployer.deploy(address(0), address(hook));
    }

    function test_wrongManagerRefused() public {
        vm.expectRevert(abi.encodeWithSelector(DeployAuxiliaries.WrongManager.selector));
        deployer.deploy(address(token), address(hook));
    }

    function test_wrongWalletRefused() public {
        MoneyBackHook other = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        vm.expectRevert(abi.encodeWithSelector(DeployAuxiliaries.WrongPayout.selector));
        deployer.deploy(address(pm), address(other));
    }

    function test_uninitializedHookRefused() public {
        MoneyBackHook other = _deployHook(address(pm), address(token), deployer.PAYING_WALLET(), EXPECTED_FLAGS);
        vm.expectRevert(abi.encodeWithSelector(DeployAuxiliaries.PoolNotInitialized.selector));
        deployer.deploy(address(pm), address(other));
    }
}
