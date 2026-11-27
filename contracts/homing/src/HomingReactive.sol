// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { IHomingVault } from "./IHoming.sol";

/// @title HomingReactive — Homing 的「大脑」，部署在 Reactive Lasna
/// @notice 三件事：
///   1. 听登记簿的 WalletAdded(wallet, owner, tag) → 记下钱包，并在每条「被监听链」上动态订阅它的 ERC-20 转出
///   2. 任意一条链上这个钱包有转出 → 刷新 lastSeen，回调金库 onActivity
///   3. 定时（Cron100，约 2 分钟一次）检查：可归集钱包闲置超过 idleSeconds → 回调金库 onSweep
///
/// 防失控：钱包数上限、时钟有次数上限（用完自动退订）、同一钱包两次归集请求至少间隔 idleSeconds、
///         onActivity 有节流、金库没设置就不回调、owner 随时可关时钟。
contract HomingReactive is AbstractReactive {
    // ───────── 常量 ─────────
    uint256 private constant TRANSFER_TOPIC0 = uint256(keccak256("Transfer(address,address,uint256)"));
    /// @dev 和 bee 已部署的登记簿一致：WalletAdded(address indexed wallet, address indexed owner, uint8 tag)
    uint256 private constant WALLET_ADDED_TOPIC0 = uint256(keccak256("WalletAdded(address,address,uint8)"));
    uint256 private constant TAG_CHANGED_TOPIC0 = uint256(keccak256("WalletTagChanged(address,uint8)"));
    uint256 private constant REMOVED_TOPIC0 = uint256(keccak256("WalletRemoved(address)"));
    address private constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 private constant CRON100_TOPIC0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    uint8 public constant TAG_DAILY = 0;
    uint8 public constant TAG_COLD = 1;
    uint8 public constant TAG_SWEEPABLE = 2;

    uint256 public constant MAX_WALLETS = 20;
    uint64 private constant ACTIVITY_GAS = 300_000;
    uint64 private constant SWEEP_GAS = 600_000;

    // ───────── 配置 ─────────
    address public immutable OWNER;
    /// @notice 登记簿 + 金库所在链（Sepolia 11155111）。归集也发生在这条链。
    uint256 public immutable REGISTRY_CHAIN_ID;
    address public immutable REGISTRY;
    /// @notice 要监听钱包活动的链（例如 [11155111, 84532]）
    uint256[] public watchChains;

    /// @notice 闲置多少秒算「被遗忘」（演示 300）
    uint256 public idleSeconds;
    /// @notice 同一个钱包两次 onActivity 回调之间至少隔多少秒（省钱）
    uint256 public activityGap;
    /// @notice 金库地址（在 REGISTRY_CHAIN_ID 上），部署金库后回来填
    address public vault;

    // ───────── 状态 ─────────
    struct Wallet {
        address owner;
        uint8 tag;
        uint64 lastSeen;
        uint64 lastReported;
        bool warned;
        bool active;
        uint64 lastRequest; // 上次请求归集的时间；0 = 还没请求过
    }

    address[] public walletList;
    mapping(address => Wallet) public wallets;
    mapping(address => bool) public tracked;

    bool public clockOn;
    uint256 public ticksLeft;

    // ───────── 事件（在 Reactscan 上看得到） ─────────
    event Tracked(address indexed wallet, address indexed owner, uint8 tag);
    event TagChanged(address indexed wallet, uint8 tag);
    event Untracked(address indexed wallet);
    event Activity(address indexed wallet, uint256 indexed chainId, uint256 seenAt, bool reported);
    event IdleWarning(address indexed wallet, uint256 idleFor);
    event SweepRequested(address indexed wallet, address vault);
    event ClockChanged(bool on, uint256 ticks);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    /// @param registryChainId_ 登记簿所在链（Sepolia 11155111）
    /// @param registry_        登记簿地址
    /// @param watchChains_     监听活动的链，例如 [11155111, 84532]
    /// @param idleSeconds_     闲置阈值秒数（演示 300）
    /// @param activityGap_     onActivity 节流秒数（演示 60）
    constructor(
        uint256 registryChainId_,
        address registry_,
        uint256[] memory watchChains_,
        uint256 idleSeconds_,
        uint256 activityGap_
    ) payable {
        OWNER = msg.sender;
        REGISTRY_CHAIN_ID = registryChainId_;
        REGISTRY = registry_;
        watchChains = watchChains_;
        idleSeconds = idleSeconds_;
        activityGap = activityGap_;
        SYSTEM.subscribe(
            registryChainId_, registry_, WALLET_ADDED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            registryChainId_, registry_, TAG_CHANGED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(registryChainId_, registry_, REMOVED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    // ───────── owner 操作 ─────────

    /// @notice 金库部署好之后回来填（金库构造函数需要本合约地址，所以只能后填）
    function setVault(address vault_) external onlyOwner {
        vault = vault_;
    }

    function setIdleSeconds(uint256 s_) external onlyOwner {
        idleSeconds = s_;
    }

    function setActivityGap(uint256 gap_) external onlyOwner {
        activityGap = gap_;
    }

    /// @notice 开/关定时检查。ticks_ = 最多跑多少次（约 2 分钟一次），跑完自动退订。
    function setClock(bool on_, uint256 ticks_) external onlyOwner {
        if (on_ && !clockOn) {
            SYSTEM.subscribe(block.chainid, CRON, CRON100_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else if (!on_ && clockOn) {
            SYSTEM.unsubscribe(block.chainid, CRON, CRON100_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        clockOn = on_;
        ticksLeft = on_ ? ticks_ : 0;
        emit ClockChanged(on_, ticksLeft);
    }

    // ───────── 核心：react ─────────

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == TRANSFER_TOPIC0) {
            // opCode 3 = LOG3（ERC-20 Transfer 有 3 个 topic）；ERC-721 是 LOG4，跳过
            if (log_.opCode == 3) _onTransfer(log_);
        } else if (log_.topic0 == CRON100_TOPIC0) {
            if (log_.contractAddress == CRON) _onTick(log_);
        } else if (log_.chainId == REGISTRY_CHAIN_ID && log_.contractAddress == REGISTRY) {
            if (log_.topic0 == WALLET_ADDED_TOPIC0) _onWalletAdded(log_);
            else if (log_.topic0 == TAG_CHANGED_TOPIC0) _onTagChanged(log_);
            else if (log_.topic0 == REMOVED_TOPIC0) _onRemoved(log_);
        }
        // 其它事件：直接 return（不要 revert，revert 也收费）
    }

    function _onWalletAdded(LogRecord calldata log_) internal {
        address wallet_ = address(uint160(log_.topic1));
        address owner_ = address(uint160(log_.topic2));
        uint8 tag_ = abi.decode(log_.data, (uint8));

        if (tag_ > TAG_SWEEPABLE) return;
        if (tracked[wallet_]) {
            // 先 remove 再重新 register：重新激活，订阅还在，不用重订
            Wallet storage old = wallets[wallet_];
            if (old.active) return;
            old.owner = owner_;
            old.tag = tag_;
            old.active = true;
            old.lastSeen = uint64(block.timestamp);
            old.warned = false;
            old.lastRequest = 0;
            emit Tracked(wallet_, owner_, tag_);
            return;
        }
        if (walletList.length >= MAX_WALLETS) return;

        tracked[wallet_] = true;
        walletList.push(wallet_);
        wallets[wallet_] = Wallet({
            owner: owner_,
            tag: tag_,
            lastSeen: uint64(block.timestamp),
            lastReported: 0,
            warned: false,
            active: true,
            lastRequest: 0
        });

        // 动态订阅：每条监听链上「任何 ERC-20 合约」里 from == 这个钱包 的 Transfer
        uint256 n = watchChains.length;
        for (uint256 i = 0; i < n; i++) {
            SYSTEM.subscribe(
                watchChains[i], address(0), TRANSFER_TOPIC0, uint256(uint160(wallet_)), REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        emit Tracked(wallet_, owner_, tag_);
    }

    function _onTagChanged(LogRecord calldata log_) internal {
        address wallet_ = address(uint160(log_.topic1));
        uint8 tag_ = abi.decode(log_.data, (uint8));
        if (!tracked[wallet_] || tag_ > TAG_SWEEPABLE) return;
        wallets[wallet_].tag = tag_;
        emit TagChanged(wallet_, tag_);
    }

    /// @dev 只标记不活跃（不退订：Transfer 订阅里 topic1 已经锁死这个地址，留着也只是偶尔多一次 return）
    function _onRemoved(LogRecord calldata log_) internal {
        address wallet_ = address(uint160(log_.topic1));
        if (!tracked[wallet_]) return;
        wallets[wallet_].active = false;
        emit Untracked(wallet_);
    }

    function _onTransfer(LogRecord calldata log_) internal {
        address from_ = address(uint160(log_.topic1));
        if (!tracked[from_]) return;

        Wallet storage w = wallets[from_];
        if (!w.active) return;
        w.lastSeen = uint64(block.timestamp);
        w.warned = false;
        w.lastRequest = 0;

        bool report = vault != address(0) && block.timestamp >= uint256(w.lastReported) + activityGap;
        emit Activity(from_, log_.chainId, block.timestamp, report);
        if (!report) return;

        w.lastReported = uint64(block.timestamp);
        _callback(
            ACTIVITY_GAS,
            abi.encodeWithSelector(
                IHomingVault.onActivity.selector, address(0), log_.chainId, log_.txHash, from_, block.timestamp
            )
        );
    }

    function _onTick(LogRecord calldata log_) internal {
        if (!clockOn || ticksLeft == 0) return;
        ticksLeft -= 1;
        if (ticksLeft == 0) {
            clockOn = false;
            SYSTEM.unsubscribe(block.chainid, CRON, CRON100_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit ClockChanged(false, 0);
        }
        if (vault == address(0)) return;

        uint256 n = walletList.length;
        for (uint256 i = 0; i < n; i++) {
            address a = walletList[i];
            Wallet storage w = wallets[a];
            if (!w.active || w.tag != TAG_SWEEPABLE) continue;

            uint256 idleFor = block.timestamp - w.lastSeen;
            if (!w.warned && idleFor * 2 >= idleSeconds) {
                w.warned = true;
                emit IdleWarning(a, idleFor); // 前端拿它显示「快被归集了」
            }
            if (idleFor < idleSeconds) continue;
            // 金库按用户自己的 wait + grace 复核，可能比这里更严 → 没到期它只会跳过。
            // 所以不能「请求一次就再也不管」：隔 idleSeconds 再请求一次（次数受 ticksLeft 限制）。
            if (w.lastRequest != 0 && block.timestamp < uint256(w.lastRequest) + idleSeconds) continue;

            w.lastRequest = uint64(block.timestamp);
            emit SweepRequested(a, vault);
            _callback(
                SWEEP_GAS,
                abi.encodeWithSelector(IHomingVault.onSweep.selector, address(0), log_.chainId, log_.txHash, a)
            );
        }
    }

    // ───────── 工具 ─────────

    function _callback(uint64 gas_, bytes memory payload_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: REGISTRY_CHAIN_ID, recipient: vault, gasLimit: gas_, payload: payload_
            })
        );
    }

    function walletCount() external view returns (uint256) {
        return walletList.length;
    }

    function watchChainCount() external view returns (uint256) {
        return watchChains.length;
    }
}
