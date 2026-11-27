// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { HomingReactive } from "../src/HomingReactive.sol";
import { IHomingVault } from "../src/IHoming.sol";

/// @dev 假的系统合约 0x8888…：记录订阅、退订、回调请求
contract MockSystem {
    struct Sub { uint256 chainId; address contract_; uint256 topic0; uint256 topic1; }
    Sub[] public subs;
    uint256 public unsubscribeCount;
    ISystemContract.CallbackConfiguration_V_1_0[] internal reqs;

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256, uint256) external { subs.push(Sub(c, a, t0, t1)); }
    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { unsubscribeCount++; }
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external { reqs.push(cfg); }
    function debt(address) external pure returns (uint256) { return 0; }
    function subCount() external view returns (uint256) { return subs.length; }
    function reqCount() external view returns (uint256) { return reqs.length; }
    function req(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) { return reqs[i]; }
    receive() external payable {}
}

/// @dev 假的目标链 Callback Proxy：把 payload 第一个参数换成 reactive 地址再投递
contract MockProxy {
    function debt(address) external pure returns (uint256) { return 0; }
    receive() external payable {}
    function deliver(address to, address reactive, bytes memory payload) external returns (bool ok) {
        assembly { mstore(add(payload, 36), reactive) }
        (ok,) = to.call(payload);
    }
}

/// @dev 最小金库：只为了验证接口签名能对上（bee 的真金库会替换它）
contract MockVault is AbstractCallback, IHomingVault {
    uint256 public activityCount;
    uint256 public sweepCount;
    address public lastWallet;

    constructor(IPayable proxy_, address reactive_) payable AbstractCallback(proxy_, reactive_) {}

    function onActivity(address rvm, uint256, uint256, address wallet, uint256) external onlyServiceProvider onlyCallbackSender(rvm) {
        activityCount++;
        lastWallet = wallet;
    }

    function onSweep(address rvm, uint256, uint256, address wallet) external onlyServiceProvider onlyCallbackSender(rvm) {
        sweepCount++;
        lastWallet = wallet;
    }
}

contract HomingReactiveTest is Test {
    uint256 constant SEPOLIA = 11155111;
    uint256 constant BASE_SEPOLIA = 84532;
    address constant SYS = 0x8888888888888888888888888888888888888888;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    uint256 WALLET_ADDED = uint256(keccak256("WalletAdded(address,address,uint8)"));
    uint256 TRANSFER = uint256(keccak256("Transfer(address,address,uint256)"));

    address registry = address(0xBEE);
    address owner_ = address(0xA11CE);
    address daily = address(0xD1);
    address forgotten = address(0xF0);
    address token = address(0x70C);

    MockSystem sys;
    MockProxy proxy;
    MockVault vault;
    HomingReactive rc;

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(payable(SYS));
        proxy = new MockProxy();
        uint256[] memory chains = new uint256[](2);
        chains[0] = SEPOLIA;
        chains[1] = BASE_SEPOLIA;
        rc = new HomingReactive{ value: 1 ether }(SEPOLIA, registry, chains, 300, 60);
        vault = new MockVault{ value: 0.1 ether }(IPayable(payable(address(proxy))), address(rc));
        vm.warp(1_000_000);
    }

    // ───── helpers ─────
    function _added(address wallet, uint8 tag) internal view returns (IReactive.LogRecord memory l) {
        l.chainId = SEPOLIA;
        l.contractAddress = registry;
        l.topic0 = WALLET_ADDED;
        l.topic1 = uint256(uint160(wallet));
        l.topic2 = uint256(uint160(owner_));
        l.data = abi.encode(tag);
        l.opCode = 3;
    }

    function _transfer(address from, uint256 chainId) internal view returns (IReactive.LogRecord memory l) {
        l.chainId = chainId;
        l.contractAddress = token;
        l.topic0 = TRANSFER;
        l.topic1 = uint256(uint160(from));
        l.topic2 = uint256(uint160(address(0x123)));
        l.data = abi.encode(uint256(1e18));
        l.opCode = 3;
    }

    function _tick() internal pure returns (IReactive.LogRecord memory l) {
        l.chainId = 5318007;
        l.contractAddress = CRON;
        l.topic0 = CRON100;
        l.opCode = 1;
    }

    function _react(IReactive.LogRecord memory l) internal {
        vm.prank(SYS);
        rc.react(l);
    }

    function _deliverLast() internal returns (bool ok) {
        ISystemContract.CallbackConfiguration_V_1_0 memory r = sys.req(sys.reqCount() - 1);
        ok = proxy.deliver(r.recipient, address(rc), r.payload);
    }

    // ───── tests ─────
    function test_subscribesRegistryInConstructor() public view {
        (uint256 c, address a, uint256 t0,) = sys.subs(0);
        assertEq(c, SEPOLIA);
        assertEq(a, registry);
        assertEq(t0, WALLET_ADDED);
    }

    function test_walletAdded_tracksAndSubscribesDynamically() public {
        _react(_added(forgotten, 2));
        assertEq(rc.walletCount(), 1);
        assertEq(sys.subCount(), 5); // 登记簿 3 个事件 + 两条链各一个
        (uint256 c1, address a1, uint256 t0, uint256 t1) = sys.subs(3);
        assertEq(c1, SEPOLIA);
        assertEq(a1, address(0));
        assertEq(t0, TRANSFER);
        assertEq(t1, uint256(uint160(forgotten)));
        (uint256 c2,,,) = sys.subs(4);
        assertEq(c2, BASE_SEPOLIA);
    }

    function test_walletAdded_ignoresFakeRegistryAndDuplicates() public {
        IReactive.LogRecord memory fake = _added(forgotten, 2);
        fake.contractAddress = address(0xBAD);
        _react(fake);
        assertEq(rc.walletCount(), 0);

        _react(_added(forgotten, 2));
        _react(_added(forgotten, 2));
        assertEq(rc.walletCount(), 1);
        assertEq(sys.subCount(), 5);
    }

    function test_activity_callsOnActivity_andThrottles() public {
        rc.setVault(address(vault));
        _react(_added(daily, 0));

        _react(_transfer(daily, SEPOLIA));
        assertEq(sys.reqCount(), 1);
        assertTrue(_deliverLast());
        assertEq(vault.activityCount(), 1);
        assertEq(vault.lastWallet(), daily);

        _react(_transfer(daily, SEPOLIA)); // 60 秒内第二次：不回调
        assertEq(sys.reqCount(), 1);

        vm.warp(block.timestamp + 61);
        _react(_transfer(daily, SEPOLIA));
        assertEq(sys.reqCount(), 2);
    }

    function test_activity_ignoresUntrackedAndNfts() public {
        rc.setVault(address(vault));
        _react(_added(daily, 0));
        _react(_transfer(address(0x999), SEPOLIA));
        IReactive.LogRecord memory nft = _transfer(daily, SEPOLIA);
        nft.opCode = 4;
        _react(nft);
        assertEq(sys.reqCount(), 0);
    }

    function test_tick_warnsThenSweepsOnce_onlySweepable() public {
        rc.setVault(address(vault));
        _react(_added(daily, 0));
        _react(_added(forgotten, 2));
        rc.setClock(true, 100);

        vm.warp(block.timestamp + 100);
        _react(_tick());
        assertEq(sys.reqCount(), 0);

        vm.warp(block.timestamp + 100); // 闲置 200 秒 ≥ 一半 → 预警，不归集
        vm.expectEmit(true, false, false, true);
        emit HomingReactive.IdleWarning(forgotten, 200);
        _react(_tick());
        assertEq(sys.reqCount(), 0);

        vm.warp(block.timestamp + 100); // 闲置 300 秒 → 归集
        _react(_tick());
        assertEq(sys.reqCount(), 1);
        assertTrue(_deliverLast());
        assertEq(vault.sweepCount(), 1);
        assertEq(vault.lastWallet(), forgotten);

        vm.warp(block.timestamp + 100); // 间隔不够 idleSeconds：不重复请求
        _react(_tick());
        assertEq(sys.reqCount(), 1);

        vm.warp(block.timestamp + 300); // 金库可能因为期限更严而跳过 → 隔一段时间重试
        _react(_tick());
        assertEq(sys.reqCount(), 2);
    }

    function test_activityResetsSweep() public {
        rc.setVault(address(vault));
        _react(_added(forgotten, 2));
        rc.setClock(true, 100);

        vm.warp(block.timestamp + 250);
        _react(_transfer(forgotten, SEPOLIA)); // 主人回来了
        vm.warp(block.timestamp + 250);
        _react(_tick());
        // 只有那次 onActivity，没有 onSweep
        assertEq(sys.reqCount(), 1);
        assertEq(bytes4(sys.req(0).payload), IHomingVault.onActivity.selector);
    }

    function test_noVault_noCallback() public {
        _react(_added(forgotten, 2));
        rc.setClock(true, 100);
        vm.warp(block.timestamp + 1000);
        _react(_tick());
        assertEq(sys.reqCount(), 0);
    }

    function test_clockRunsOutAndUnsubscribes() public {
        rc.setClock(true, 2);
        _react(_tick());
        _react(_tick());
        assertFalse(rc.clockOn());
        assertEq(sys.unsubscribeCount(), 1);
        _react(_tick()); // 再来也没反应
        assertEq(rc.ticksLeft(), 0);
    }

    function test_onlySystemAndOwner() public {
        vm.expectRevert();
        rc.react(_tick());
        vm.prank(address(0xBAD));
        vm.expectRevert(HomingReactive.NotOwner.selector);
        rc.setVault(address(1));
    }

    function test_vaultRejectsStrangers() public {
        vm.expectRevert();
        vault.onSweep(address(rc), SEPOLIA, 0, forgotten); // 不是 proxy 发来的
        bytes memory p = abi.encodeWithSelector(IHomingVault.onSweep.selector, address(0), SEPOLIA, 0, forgotten);
        bool ok = proxy.deliver(address(vault), address(0xBAD), p); // 冒充别的 reactive
        assertFalse(ok);
    }

    function test_activityOnOtherChainCounts() public {
        rc.setVault(address(vault));
        _react(_added(forgotten, 2));
        rc.setClock(true, 100);
        vm.warp(block.timestamp + 250);
        _react(_transfer(forgotten, BASE_SEPOLIA)); // 在 Base Sepolia 动了一下
        assertEq(sys.reqCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory r = sys.req(0);
        assertEq(r.chainId, SEPOLIA); // 回调仍然发到 Sepolia 的金库
        vm.warp(block.timestamp + 250);
        _react(_tick());
        assertEq(sys.reqCount(), 1); // 没被归集
    }

    function test_tagChangeAndRemove() public {
        rc.setVault(address(vault));
        _react(_added(forgotten, 2));
        rc.setClock(true, 100);

        IReactive.LogRecord memory l;
        l.chainId = SEPOLIA;
        l.contractAddress = registry;
        l.topic0 = uint256(keccak256("WalletTagChanged(address,uint8)"));
        l.topic1 = uint256(uint160(forgotten));
        l.data = abi.encode(uint8(1)); // 改成冷钱包
        _react(l);
        vm.warp(block.timestamp + 1000);
        _react(_tick());
        assertEq(sys.reqCount(), 0); // 冷钱包不归集

        l.topic0 = uint256(keccak256("WalletRemoved(address)"));
        l.data = "";
        _react(l);
        _react(_transfer(forgotten, SEPOLIA));
        assertEq(sys.reqCount(), 0); // 已移除：活动也不再上报

        _react(_added(forgotten, 2)); // 重新登记 → 重新激活
        _react(_transfer(forgotten, SEPOLIA));
        assertEq(sys.reqCount(), 1);
    }
}
