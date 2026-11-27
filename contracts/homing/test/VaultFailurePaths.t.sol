// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { WalletRegistry } from "../src/WalletRegistry.sol";
import { Vault } from "../src/Vault.sol";

/// @notice 测试用的最小 ERC20（与 Vault.t.sol 里的同一个，只是本文件自带一份，
///         这样本文件拷进 starter/test 就能直接跑，不用改原文件）。
contract MockERC20B {
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

/// @notice bee 的失败路径补测：Vault.t.sol 已有 10 个测试（含 2 个失败实验），
///         这里补 12 个明天全链路最怕踩的坑——活动同步鉴权与旧数据、
///         授权被撤/余额为零/坏代币时的归集、继承冒充与二次领取、
///         含冷钱包的继承、登记簿的坏标签与重复登记。
///         跑法：把本文件拷进 starter/test/，forge test，全绿应为 22 个测试
///         （原 10 个 + 本文件 12 个）。
contract VaultFailurePathsTest is Test {
    WalletRegistry registry;
    MockERC20B token;
    Vault vault;

    address proxy = address(0xAAAA);
    address reactive = address(0xBBBB);
    address owner = address(0x1111); // 日常钱包（主人），也是归集目的地
    address forgotten = address(0x2222); // 可归集钱包
    address cold = address(0x3333); // 冷钱包
    address heir = address(0x4444);

    function setUp() public {
        registry = new WalletRegistry();
        token = new MockERC20B();
        vault = new Vault(IPayable(payable(proxy)), reactive, 1 days);

        vm.prank(forgotten);
        registry.register(owner, 2); // 可归集
        vm.prank(cold);
        registry.register(owner, 1); // 冷钱包

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

        token.mint(forgotten, 100 ether);
        token.mint(cold, 100 ether);
        vm.prank(forgotten);
        token.approve(address(vault), type(uint256).max);
        vm.prank(cold);
        token.approve(address(vault), type(uint256).max);
    }

    /// 活动同步也要鉴权：不是 Proxy 的人调 onActivity，直接被拒
    /// （只测了 onSweep 的鉴权不够——Yilin 的合约天天调的是 onActivity）
    function test_activityRejectsWrongProxy() public {
        vm.prank(address(0x9999));
        vm.expectRevert();
        vault.onActivity(reactive, 11155111, 0x1234, forgotten, block.timestamp);
    }

    /// Proxy 没错，但 payload 里的 reactive 不是 Yilin 的合约，onActivity 也被拒
    function test_activityRejectsWrongSender() public {
        vm.prank(proxy);
        vm.expectRevert();
        vault.onActivity(address(0xCCCC), 11155111, 0x1234, forgotten, block.timestamp);
    }

    /// 旧数据不能把时间往回拨：先同步到 +10 天，再来一条迟到的 +1 天数据，
    /// 最后活跃时间必须还停在 +10 天（事件乱序到达时这点很关键）
    function test_activityStaleTimestampIgnored() public {
        uint256 now_ = block.timestamp;
        vm.prank(proxy);
        vault.onActivity(reactive, 11155111, 0x1234, forgotten, now_ + 10 days);
        assertEq(vault.lastActivity(forgotten), now_ + 10 days);
        vm.prank(proxy);
        vault.onActivity(reactive, 11155111, 0x1234, forgotten, now_ + 1 days);
        assertEq(vault.lastActivity(forgotten), now_ + 10 days);
    }

    /// 没链接过的钱包发来活动同步：静默忽略，不 revert、也不建记录
    function test_activityUnknownWalletIgnored() public {
        address stranger = address(0x7777);
        vm.prank(proxy);
        vault.onActivity(reactive, 11155111, 0x1234, stranger, block.timestamp);
        assertEq(vault.walletOwner(stranger), address(0));
    }

    /// 用户临归集前撤回授权：归集回调不能 revert（回调 revert 照样收费、
    /// 事件还丢了），只能跳过，钱留在原地
    function test_sweepWithRevokedAllowanceSkips() public {
        vm.warp(block.timestamp + 37 days);
        vm.prank(forgotten);
        token.approve(address(vault), 0); // 用户撤回授权
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, forgotten);
        assertEq(token.balanceOf(forgotten), 100 ether);
        assertEq(token.balanceOf(owner), 0);
    }

    /// 余额为零的钱包：归集只跳过，不 revert
    function test_sweepEmptyWalletSkips() public {
        address empty = address(0x6666);
        vm.prank(owner);
        vault.linkWallet(empty, 2);
        vm.warp(block.timestamp + 37 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, empty);
        assertEq(token.balanceOf(empty), 0);
    }

    /// 多代币、一个坏了不连累其他：第一个代币授权被撤（转不走），
    /// 第二个代币照常归集——try/catch 是按代币隔离的
    function test_sweepOneBadTokenDoesNotBlockOthers() public {
        MockERC20B token2 = new MockERC20B();
        token2.mint(forgotten, 50 ether);
        vm.prank(forgotten);
        token2.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        vault.setTokenAllowed(address(token2), true);
        vm.prank(forgotten);
        token.approve(address(vault), 0); // 第一个代币授权被撤，模拟坏代币
        vm.warp(block.timestamp + 37 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, forgotten);
        assertEq(token2.balanceOf(owner), 50 ether); // 好的代币照常归集
        assertEq(token.balanceOf(forgotten), 100 ether); // 坏的留在原地
    }

    /// 冒充继承人来领：被拒
    function test_claimRejectsNonHeir() public {
        vm.warp(block.timestamp + 366 days);
        vm.prank(address(0x8888));
        vm.expectRevert();
        vault.claim(owner);
    }

    /// 继承只能领一次：第二次来领被拒
    function test_claimTwiceReverts() public {
        vm.warp(block.timestamp + 366 days);
        vm.prank(heir);
        vault.claim(owner);
        vm.prank(heir);
        vm.expectRevert();
        vault.claim(owner);
    }

    /// 继承含冷钱包：配置改成 coldIncluded=true 后，继承人领走
    /// 可归集钱包 + 冷钱包的币，共 200 个
    function test_claimIncludesColdWhenEnabled() public {
        vm.prank(owner);
        vault.configure(owner, heir, 30 days, 7 days, 365 days, true);
        vm.warp(block.timestamp + 366 days);
        vm.prank(heir);
        vault.claim(owner);
        assertEq(token.balanceOf(heir), 200 ether);
        assertEq(token.balanceOf(cold), 0);
    }

    /// 登记簿：标签只能是 0/1/2，登记过的钱包不能再登记
    function test_registryRejectsBadTagAndDoubleRegister() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.register(owner, 3);
        vm.prank(forgotten);
        vm.expectRevert();
        registry.register(owner, 2);
    }

    /// 日常钱包（tag 0）是归集目的地：对它发归集回调只跳过，不会被归集
    function test_sweepPrimaryWalletSkips() public {
        vm.warp(block.timestamp + 37 days);
        vm.prank(proxy);
        vault.onSweep(reactive, 11155111, 0x1234, owner);
        assertEq(token.balanceOf(owner), 0);
    }
}
