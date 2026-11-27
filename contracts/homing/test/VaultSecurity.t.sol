// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { WalletRegistry } from "../src/WalletRegistry.sol";
import { Vault, IWalletRegistry } from "../src/Vault.sol";

contract SecToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a && balanceOf[f] >= a);
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @notice v2 安全修复的回归测试：每个都对应一个修掉的漏洞
contract VaultSecurityTest is Test {
    WalletRegistry registry;
    SecToken token;
    Vault vault;
    address proxy = address(0xAAAA);
    address reactive = address(0xBBBB);
    address owner = address(0x1111);
    address victim = address(0x2222); // owner 的可归集钱包
    address heir = address(0x4444);
    address attacker = address(0x6666);

    function setUp() public {
        registry = new WalletRegistry();
        token = new SecToken();
        vault = new Vault(IPayable(payable(proxy)), reactive, 1 days, IWalletRegistry(address(registry)));
        vm.prank(owner);
        registry.register(owner, 0);
        vm.prank(victim);
        registry.register(owner, 2);
        vm.startPrank(owner);
        vault.configure(owner, heir, 30 days, 7 days, 365 days, false);
        vault.linkWallet(owner);
        vault.linkWallet(victim);
        vault.setTokenAllowed(address(token), true);
        vm.stopPrank();
        token.mint(owner, 10 ether);
        token.mint(victim, 100 ether);
        vm.prank(owner);
        token.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        token.approve(address(vault), type(uint256).max);
    }

    /// 漏洞 1：攻击者把别人的钱包挂到自己名下 → 被拒
    function test_attackerCannotLinkSomeoneElsesWallet() public {
        vm.startPrank(attacker);
        vault.configure(attacker, attacker, 0, 0, 0, false);
        vm.expectRevert(Vault.NotYourWallet.selector);
        vault.linkWallet(victim);
        vm.stopPrank();
        assertEq(vault.walletOwner(victim), owner);

        vm.warp(block.timestamp + 37 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0, victim);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(owner), 110 ether); // 钱回到真正的主人
    }

    /// 漏洞 1（变体）：钱包没在登记簿登记，主人也不能直接 link
    function test_cannotLinkUnregisteredWallet() public {
        vm.prank(owner);
        vm.expectRevert(Vault.NotYourWallet.selector);
        vault.linkWallet(address(0x7777));
    }

    /// 漏洞 2：configure 不能再调一次来立刻换继承人
    function test_configureOnlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(Vault.AlreadyConfigured.selector);
        vault.configure(owner, attacker, 30 days, 7 days, 1, false);
        (, address h,,,,,) = vault.configs(owner);
        assertEq(h, heir);
    }

    /// 问题 3：继承时主钱包也交给继承人
    function test_claimIncludesPrimary() public {
        vm.warp(block.timestamp + 366 days);
        vm.prank(heir);
        vault.claim(owner);
        assertEq(token.balanceOf(heir), 110 ether); // 主钱包 10 + 可归集 100
    }

    /// 问题 4：在登记簿移除的钱包，不再被归集、也不被继承、也不挡继承
    function test_removedWalletIsLeftAlone() public {
        vm.prank(victim);
        registry.remove();
        vm.warp(block.timestamp + 366 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0, victim);
        assertEq(token.balanceOf(victim), 100 ether);
        vm.prank(heir);
        vault.claim(owner);
        assertEq(token.balanceOf(victim), 100 ether);
        assertEq(token.balanceOf(heir), 10 ether);
    }

    /// 标签以登记簿为准：在登记簿把可归集改成冷钱包，金库马上不归集
    function test_tagChangeInRegistryTakesEffect() public {
        vm.prank(victim);
        registry.setTag(1);
        assertEq(vault.walletTag(victim), 1);
        vm.warp(block.timestamp + 37 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0, victim);
        assertEq(token.balanceOf(victim), 100 ether);
    }
}
