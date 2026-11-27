// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { WalletRegistry } from "../src/WalletRegistry.sol";
import { Vault } from "../src/Vault.sol";

/// @notice 测试用的最小 ERC20：Homing 的归集靠授权 + transferFrom，需要它来演。
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        require(balanceOf[from_] >= amount_, "balance");
        require(allowance[from_][msg.sender] >= amount_, "allowance");
        allowance[from_][msg.sender] -= amount_;
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        return true;
    }
}

/// @notice bee 的失败实验 + MVP 核心行为测试（Homing 版）：
///         归集全程用 vm.prank 冒充 Callback Proxy 调金库的回调入口。
contract VaultTest is Test {
    WalletRegistry registry;
    MockERC20 token;
    Vault vault;

    address proxy = address(0xAAAA);
    address reactive = address(0xBBBB);
    address owner = address(0x1111); // 日常钱包（主人），也是归集目的地
    address forgotten = address(0x2222); // 可归集钱包
    address cold = address(0x3333); // 冷钱包
    address heir = address(0x4444);

    function setUp() public {
        registry = new WalletRegistry();
        token = new MockERC20();
        vault = new Vault(IPayable(payable(proxy)), reactive, 1 days);

        // 登记簿：两个钱包各自来登记，都归 owner
        vm.prank(forgotten);
        registry.register(owner, 2); // 可归集
        vm.prank(cold);
        registry.register(owner, 1); // 冷钱包

        // 金库：owner 写规则——等待期 30 天、宽限期 7 天、继承期 365 天、继承不含冷钱包
        vm.prank(owner);
        vault.configure(owner, heir, 30 days, 7 days, 365 days, false);
        vm.prank(owner);
        vault.linkWallet(owner, 0); // 日常钱包
        vm.prank(owner);
        vault.linkWallet(forgotten, 2);
        vm.prank(owner);
        vault.linkWallet(cold, 1);
        vm.prank(owner);
        vault.setTokenAllowed(address(token), true);

        // 两个钱包各有 100 个币，都授权给金库
        token.mint(forgotten, 100 ether);
        token.mint(cold, 100 ether);
        vm.prank(forgotten);
        token.approve(address(vault), type(uint256).max);
        vm.prank(cold);
        token.approve(address(vault), type(uint256).max);
    }

    function test_registerStoresFields() public {
        vm.prank(owner);
        registry.register(owner, 0); // 日常钱包本人登记
        WalletRegistry.Entry memory e = registry.getEntry(forgotten);
        assertEq(e.owner, owner);
        assertEq(e.tag, 2);
        assertTrue(e.active);
        WalletRegistry.Entry memory c = registry.getEntry(cold);
        assertEq(c.tag, 1);
    }

    /// 失败实验 1：不是 Proxy 的人调归集回调，直接被拒
    function test_callbackRejectsWrongProxy() public {
        vm.prank(address(0x9999));
        vm.expectRevert();
        vault.onSweep(reactive, 11155111, 0x1234, forgotten);
    }

    /// 失败实验 2：Proxy 没错，但 payload 里的 reactive 不是 Yilin 的合约，直接被拒
    function test_callbackRejectsWrongSender() public {
        vm.prank(proxy);
        vm.expectRevert();
        vault.onSweep(address(0xCCCC), 11155111, 0x1234, forgotten);
    }

    /// 期限复核：刚登记就收到归集回调，复核不过、只跳过，钱不动
    function test_sweepSkippedBeforeDeadline() public {
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, forgotten);
        assertEq(token.balanceOf(forgotten), 100 ether);
        assertEq(token.balanceOf(owner), 0);
    }

    /// 归集执行：沉默满 30 天等待 + 7 天宽限后回调，100 个币全归集到日常钱包
    function test_sweepExecutesAfterWaitAndGrace() public {
        vm.warp(block.timestamp + 37 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, forgotten);
        assertEq(token.balanceOf(forgotten), 0);
        assertEq(token.balanceOf(owner), 100 ether);
    }

    /// 钱包复活：临归集前同步到新活动，复核按新时间算，归集被取消
    function test_activitySyncCancelsSweep() public {
        vm.warp(block.timestamp + 36 days);
        vm.prank(proxy);
        vault.onActivity(reactive, 11155111, 0x1234, forgotten, block.timestamp);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, forgotten);
        assertEq(token.balanceOf(forgotten), 100 ether);
    }

    /// 冷钱包永不归集：沉默再久，归集回调也只跳过
    function test_coldWalletNeverSwept() public {
        vm.warp(block.timestamp + 400 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, cold);
        assertEq(token.balanceOf(cold), 100 ether);
    }

    /// 继承太早：才沉默 40 天，继承人来领会被拒（还有钱包在期限内）
    function test_claimTooEarlyReverts() public {
        vm.warp(block.timestamp + 40 days);
        vm.prank(heir);
        vm.expectRevert();
        vault.claim(owner);
    }

    /// 继承执行：全部钱包沉默满 365 天，继承人领走可归集钱包的币；
    /// 冷钱包没开启包含，币留在原地
    function test_claimAfterAllSilentPeriod() public {
        vm.warp(block.timestamp + 366 days);
        vm.prank(heir);
        vault.claim(owner);
        assertEq(token.balanceOf(heir), 100 ether);
        assertEq(token.balanceOf(forgotten), 0);
        assertEq(token.balanceOf(cold), 100 ether);
        assertTrue(vault.claimed(owner));
    }

    /// 改归集地址：没过延迟期应用会被拒；过了一天才生效
    function test_configChangeNeedsDelay() public {
        address newTarget = address(0x5555);
        vm.prank(owner);
        vault.requestConfigChange(newTarget, heir);
        vm.prank(owner);
        vm.expectRevert();
        vault.applyConfigChange();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        vault.applyConfigChange();
        (address sweepTarget,,,,,,) = vault.configs(owner);
        assertEq(sweepTarget, newTarget);
    }
}
