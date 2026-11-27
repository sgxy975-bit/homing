// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { HomingReactive } from "../src/HomingReactive.sol";
import { WalletRegistry } from "../src/WalletRegistry.sol";
import { Vault } from "../src/Vault.sol";
import { MockSystem, MockProxy } from "./HomingReactive.t.sol";

contract E2EToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @notice 全链路：bee 的登记簿发事件 → Yilin 的 Reactive 判断 → Proxy 投递 → bee 的金库真的归集
contract EndToEndTest is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 constant SEPOLIA = 11155111;

    MockSystem sys;
    MockProxy proxy;
    WalletRegistry registry;
    HomingReactive rc;
    Vault vault;
    E2EToken token;

    address owner = address(0x1111);
    address forgotten = address(0x2222);
    address heir = address(0x4444);

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(payable(SYS));
        proxy = new MockProxy();
        registry = new WalletRegistry();
        token = new E2EToken();
        vm.warp(1_000_000);

        uint256[] memory chains = new uint256[](2);
        chains[0] = SEPOLIA;
        chains[1] = 84532;
        rc = new HomingReactive{ value: 1 ether }(SEPOLIA, address(registry), chains, 300, 60);
        vault = new Vault{ value: 0.1 ether }(IPayable(payable(address(proxy))), address(rc), 1 days);
        rc.setVault(address(vault));
        rc.setClock(true, 100);

        // 用户在金库里配置：演示用 等待 240 秒 + 宽限 60 秒 = 300 秒
        vm.startPrank(owner);
        vault.configure(owner, heir, 240, 60, 365 days, false);
        vault.linkWallet(owner, 0);
        vault.linkWallet(forgotten, 2);
        vault.setTokenAllowed(address(token), true);
        vm.stopPrank();
        token.mint(forgotten, 100 ether);
        vm.prank(forgotten);
        token.approve(address(vault), type(uint256).max);

        // 钱包本人在登记簿登记 → 产生 WalletAdded
        vm.recordLogs();
        vm.prank(forgotten);
        registry.register(owner, 2);
        _forward(vm.getRecordedLogs());
    }

    /// 把真实合约发出的日志转成 LogRecord 喂给 react()（模拟 Reactive Network）
    function _forward(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            IReactive.LogRecord memory l;
            l.chainId = SEPOLIA;
            l.contractAddress = logs[i].emitter;
            l.opCode = logs[i].topics.length;
            l.topic0 = uint256(logs[i].topics[0]);
            if (logs[i].topics.length > 1) l.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) l.topic2 = uint256(logs[i].topics[2]);
            if (logs[i].topics.length > 3) l.topic3 = uint256(logs[i].topics[3]);
            l.data = logs[i].data;
            l.txHash = 0xabc;
            vm.prank(SYS);
            rc.react(l);
        }
    }

    function _tick() internal {
        IReactive.LogRecord memory l;
        l.chainId = 5318007;
        l.contractAddress = CRON;
        l.topic0 = CRON100;
        l.txHash = 0xc0ffee;
        vm.prank(SYS);
        rc.react(l);
    }

    /// 投递所有还没投递的回调（模拟 Callback Proxy）
    uint256 delivered;
    function _deliverAll() internal {
        while (delivered < sys.reqCount()) {
            ISystemContract.CallbackConfiguration_V_1_0 memory r = sys.req(delivered++);
            assertEq(r.chainId, SEPOLIA);
            assertTrue(proxy.deliver(r.recipient, address(rc), r.payload));
        }
    }

    function test_e2e_forgottenWalletComesHome() public {
        assertEq(rc.walletCount(), 1);

        vm.warp(block.timestamp + 301);
        _tick();
        _deliverAll();

        assertEq(token.balanceOf(forgotten), 0);
        assertEq(token.balanceOf(owner), 100 ether);
    }

    function test_e2e_activityKeepsWalletAlive() public {
        vm.warp(block.timestamp + 250);
        // 钱包在链上转了一笔（任意 ERC-20）→ Reactive 收到 Transfer
        IReactive.LogRecord memory t;
        t.chainId = 84532; // 在 Base Sepolia 动的
        t.contractAddress = address(0x70C);
        t.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        t.topic1 = uint256(uint160(forgotten));
        t.topic2 = uint256(uint160(address(0x99)));
        t.opCode = 3;
        t.txHash = 0xdef;
        vm.prank(SYS);
        rc.react(t);
        _deliverAll();
        assertEq(vault.lastActivity(forgotten), block.timestamp);

        vm.warp(block.timestamp + 100);
        _tick();
        _deliverAll();
        assertEq(token.balanceOf(forgotten), 100 ether); // 没被归集
    }

    function test_e2e_vaultStricterThanReactive_retriesLater() public {
        // 用户把金库期限改严：等待 600 + 宽限 0
        vm.prank(owner);
        vault.configure(owner, heir, 600, 0, 365 days, false);

        vm.warp(block.timestamp + 301);
        _tick();
        _deliverAll(); // Reactive 觉得到期了，金库复核没过 → 跳过
        assertEq(token.balanceOf(forgotten), 100 ether);

        vm.warp(block.timestamp + 301); // 共 602 秒
        _tick();
        _deliverAll(); // 重试 → 这次复核通过
        assertEq(token.balanceOf(owner), 100 ether);
    }
}
