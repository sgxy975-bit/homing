// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title Vault — bee 的金库合约（目标链），Homing MVP 版
/// @notice 不托管：金库只持有用户各钱包给的代币授权（approve），钱始终在用户钱包里，
///         规则触发时才用 transferFrom 归集。动任何钱之前，金库在自己这条链上
///         用本地同步来的数据重新检查期限（期限复核），不符合就跳过、不 revert
///         （回调里 revert 照样收费，这是读懂费用任务的教训）。
///         鉴权与 CampCallback 完全一致：onlyServiceProvider + onlyCallbackSender。
///
/// @dev 接口约定（今晚必须和 Yilin 对齐，见文档接口表）：
///      1) onActivity(address,uint256,uint256,address,uint256)
///         Yilin 每观察到某钱包活动，就回调同步它的最后活跃时间。
///      2) onSweep(address,uint256,uint256,address)
///         Yilin 判定某钱包沉默满等待期 + 宽限期后，回调请求归集；
///         金库复核通过才真正动钱。
///      两个签名的第一个参数照例是 address(0) 占位，Proxy 会替换成 Yilin 的合约地址。
///      继承不在回调里推：用户全部钱包长期沉默后，继承人自己调 claim()，
///      金库自查期限——用户失联后系统不再花钱（Homing README 的费用设计）。
contract Vault is AbstractCallback {
    event Configured(address indexed owner, address sweepTarget, address heir);
    event WalletLinked(address indexed owner, address indexed wallet, uint8 tag);
    event TokenAllowed(address indexed owner, address indexed token, bool allowed);
    event ActivitySynced(address indexed wallet, uint256 lastActivity);
    event Swept(address indexed wallet, address indexed token, uint256 amount);
    event SweepSkipped(address indexed wallet, uint256 reason);
    event ConfigChangeRequested(address indexed owner, address newSweepTarget, address newHeir, uint256 effectiveAt);
    event ConfigChanged(address indexed owner, address sweepTarget, address heir);
    event InheritanceClaimed(address indexed owner, address indexed wallet, address indexed token, uint256 amount);

    error ZeroAddress();
    error NotConfigured();
    error NotHeir();
    error AlreadyClaimed();
    error StillActive();
    error NoPendingChange();
    error TooEarly();

    uint8 public constant TAG_PRIMARY = 0;
    uint8 public constant TAG_COLD = 1;
    uint8 public constant TAG_SWEEPABLE = 2;

    // SweepSkipped 原因码：0 未链接或无配置/已领取，1 标签不可归集（日常/冷钱包），
    // 2 期限未到（复核没过），3 没有可归集的余额

    struct Config {
        address sweepTarget; // 归集目的地（用户的日常钱包）
        address heir;
        uint256 waitPeriod; // 单个钱包沉默多久进入宽限期
        uint256 gracePeriod; // 宽限期，过后才归集
        uint256 inheritPeriod; // 全部钱包沉默多久后继承人可领取（骨架把守护期并进这一段）
        bool coldIncluded; // 继承时是否包含冷钱包（README：冷钱包要用户主动开启）
        bool exists;
    }

    /// @notice 归集地址/继承人修改的生效延迟（README 安全设计：改了要等，防临期钻空子）
    uint256 public immutable CHANGE_DELAY;

    mapping(address => Config) public configs; // owner => 规则
    mapping(address => address) public walletOwner; // wallet => owner
    mapping(address => uint8) public walletTag; // wallet => 标签（金库本地的一份）
    mapping(address => uint256) public lastActivity; // wallet => 最后活跃时间（回调同步进来）
    mapping(address => address[]) public ownerWallets; // owner => 他的钱包们
    mapping(address => address[]) public ownerTokens; // owner => 可归集代币清单
    mapping(address => mapping(address => bool)) public tokenAllowed; // owner => token => 是否在清单
    mapping(address => address) public pendingSweepTarget;
    mapping(address => address) public pendingHeir;
    mapping(address => uint256) public pendingEffectiveAt;
    mapping(address => bool) public claimed; // owner => 继承是否已领取

    constructor(IPayable proxy_, address reactive_, uint256 changeDelay_) payable AbstractCallback(proxy_, reactive_) {
        CHANGE_DELAY = changeDelay_;
    }

    // ---------- 用户配置（在目标链上直接调） ----------

    function configure(
        address sweepTarget_,
        address heir_,
        uint256 waitPeriod_,
        uint256 gracePeriod_,
        uint256 inheritPeriod_,
        bool coldIncluded_
    ) external {
        if (sweepTarget_ == address(0) || heir_ == address(0)) revert ZeroAddress();
        configs[msg.sender] = Config({
            sweepTarget: sweepTarget_,
            heir: heir_,
            waitPeriod: waitPeriod_,
            gracePeriod: gracePeriod_,
            inheritPeriod: inheritPeriod_,
            coldIncluded: coldIncluded_,
            exists: true
        });
        emit Configured(msg.sender, sweepTarget_, heir_);
    }

    /// @notice 把自己名下的一个钱包链到金库：告诉金库它的标签。
    ///         链接动作本身算一次活动，lastActivity 先记为现在，
    ///         之后靠 onActivity 回调持续同步。
    function linkWallet(address wallet_, uint8 tag_) external {
        require(configs[msg.sender].exists, "configure first");
        require(tag_ <= 2, "bad tag");
        if (walletOwner[wallet_] == address(0)) {
            ownerWallets[msg.sender].push(wallet_);
        }
        walletOwner[wallet_] = msg.sender;
        walletTag[wallet_] = tag_;
        lastActivity[wallet_] = block.timestamp;
        emit WalletLinked(msg.sender, wallet_, tag_);
    }

    function setTokenAllowed(address token_, bool allowed_) external {
        require(configs[msg.sender].exists, "configure first");
        if (allowed_ && !tokenAllowed[msg.sender][token_]) {
            ownerTokens[msg.sender].push(token_);
        }
        tokenAllowed[msg.sender][token_] = allowed_;
        emit TokenAllowed(msg.sender, token_, allowed_);
    }

    // ---------- 回调入口（只有 Yilin 的 Reactive 合约经 Proxy 能进） ----------

    /// @notice 同步某钱包的最后活跃时间。只往前推，不被旧数据覆盖。
    function onActivity(address sender_, uint256, uint256, address wallet_, uint256 lastActivity_)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        if (walletOwner[wallet_] == address(0)) return;
        if (lastActivity_ > lastActivity[wallet_]) {
            lastActivity[wallet_] = lastActivity_;
            emit ActivitySynced(wallet_, lastActivity_);
        }
    }

    /// @notice 归集请求。先复核、后动钱；复核不过只发 Skipped 事件，不 revert。
    function onSweep(address sender_, uint256, uint256, address wallet_)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        address owner = walletOwner[wallet_];
        Config memory cfg = configs[owner];
        if (owner == address(0) || !cfg.exists || claimed[owner]) {
            emit SweepSkipped(wallet_, 0);
            return;
        }
        if (walletTag[wallet_] != TAG_SWEEPABLE) {
            emit SweepSkipped(wallet_, 1);
            return;
        }
        // 期限复核：沉默时长 = 等待期 + 宽限期，都过了才行
        if (block.timestamp < lastActivity[wallet_] + cfg.waitPeriod + cfg.gracePeriod) {
            emit SweepSkipped(wallet_, 2);
            return;
        }
        uint256 moved = _sweepAll(owner, wallet_, cfg.sweepTarget);
        if (moved == 0) emit SweepSkipped(wallet_, 3);
    }

    // ---------- 继承领取（继承人主动调，金库自查） ----------

    /// @notice 全部钱包沉默满 inheritPeriod 后，继承人来领。
    ///         任何一个钱包最近有活动都会被拒——这是金库自己的最后一道检查。
    function claim(address owner_) external {
        Config memory cfg = configs[owner_];
        if (!cfg.exists) revert NotConfigured();
        if (msg.sender != cfg.heir) revert NotHeir();
        if (claimed[owner_]) revert AlreadyClaimed();
        address[] memory wallets = ownerWallets[owner_];
        for (uint256 i = 0; i < wallets.length; i++) {
            if (block.timestamp < lastActivity[wallets[i]] + cfg.inheritPeriod) {
                revert StillActive();
            }
        }
        claimed[owner_] = true;
        for (uint256 i = 0; i < wallets.length; i++) {
            uint8 tag = walletTag[wallets[i]];
            if (tag == TAG_COLD && !cfg.coldIncluded) continue;
            if (tag == TAG_PRIMARY) continue; // 日常钱包是主人活动信号，不在领取范围
            _sweepAll(owner_, wallets[i], cfg.heir);
        }
    }

    // ---------- 修改归集地址 / 继承人（申请 + 延迟生效） ----------

    function requestConfigChange(address newSweepTarget_, address newHeir_) external {
        require(configs[msg.sender].exists, "configure first");
        if (newSweepTarget_ == address(0) || newHeir_ == address(0)) revert ZeroAddress();
        pendingSweepTarget[msg.sender] = newSweepTarget_;
        pendingHeir[msg.sender] = newHeir_;
        pendingEffectiveAt[msg.sender] = block.timestamp + CHANGE_DELAY;
        emit ConfigChangeRequested(msg.sender, newSweepTarget_, newHeir_, pendingEffectiveAt[msg.sender]);
    }

    function applyConfigChange() external {
        uint256 effectiveAt = pendingEffectiveAt[msg.sender];
        if (effectiveAt == 0) revert NoPendingChange();
        if (block.timestamp < effectiveAt) revert TooEarly();
        configs[msg.sender].sweepTarget = pendingSweepTarget[msg.sender];
        configs[msg.sender].heir = pendingHeir[msg.sender];
        delete pendingSweepTarget[msg.sender];
        delete pendingHeir[msg.sender];
        delete pendingEffectiveAt[msg.sender];
        emit ConfigChanged(msg.sender, configs[msg.sender].sweepTarget, configs[msg.sender].heir);
    }

    // ---------- 内部 ----------

    /// @notice 用授权把某钱包在清单里的代币全数转到 target；单个代币失败不连累其他代币。
    function _sweepAll(address owner_, address wallet_, address target_) internal returns (uint256 moved_) {
        address[] memory tokens = ownerTokens[owner_];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!tokenAllowed[owner_][tokens[i]]) continue;
            IERC20 token = IERC20(tokens[i]);
            uint256 bal = token.balanceOf(wallet_);
            if (bal == 0) continue;
            try token.transferFrom(wallet_, target_, bal) returns (bool ok) {
                if (ok) {
                    moved_ += bal;
                    emit Swept(wallet_, tokens[i], bal);
                }
            } catch {}
        }
    }
}
