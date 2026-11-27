// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice 只读登记簿：金库以登记簿为准判断「这个钱包属于谁、是什么标签、还在不在」
interface IWalletRegistry {
    struct Entry {
        address owner;
        uint8 tag;
        bool active;
    }

    function getEntry(address wallet_) external view returns (Entry memory);
}

/// @title Vault — bee 的金库合约（目标链），Homing MVP 版
/// @notice 不托管：金库只持有用户各钱包给的代币授权（approve），钱始终在用户钱包里，
///         规则触发时才用 transferFrom 归集。动任何钱之前，金库在自己这条链上
///         用本地同步来的数据重新检查期限（期限复核），不符合就跳过、不 revert
///         （回调里 revert 照样收费，这是读懂费用任务的教训）。
///         鉴权与 CampCallback 完全一致：onlyServiceProvider + onlyCallbackSender。
///
/// @dev v2（安全修复，Yilin）：
///      1) 钱包归属以登记簿为准：只有钱包本人在登记簿里声明属于你，你才能 linkWallet，
///         防止别人把你的钱包挂到他名下、再把钱「归集」给自己。
///      2) configure 只能调一次；之后改归集地址 / 继承人只能走 requestConfigChange（有等待期）。
///      3) 标签每次都从登记簿实时读：在登记簿改标签或移除钱包，金库马上生效。
///      4) 继承时主钱包也一起交给继承人（冷钱包仍需用户事先开启）；
///         已移除或已换主人的钱包不算、也不会被领走。
///
///      接口：onActivity(address,uint256,uint256,address,uint256) / onSweep(address,uint256,uint256,address)
///      两个签名的第一个参数照例是 address(0) 占位，Proxy 会替换成 Reactive 合约地址。
///      继承不在回调里推：用户全部钱包长期沉默后，继承人自己调 claim()，金库自查期限。
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
    error AlreadyConfigured();
    error NotYourWallet();
    error NotHeir();
    error AlreadyClaimed();
    error StillActive();
    error NoPendingChange();
    error TooEarly();

    uint8 public constant TAG_PRIMARY = 0;
    uint8 public constant TAG_COLD = 1;
    uint8 public constant TAG_SWEEPABLE = 2;
    uint8 private constant TAG_NONE = type(uint8).max;

    // SweepSkipped 原因码：0 未链接或无配置/已领取/登记簿里已不属于该主人，1 标签不可归集（日常/冷钱包），
    // 2 期限未到（复核没过），3 没有可归集的余额

    struct Config {
        address sweepTarget; // 归集目的地（用户的日常钱包）
        address heir;
        uint256 waitPeriod; // 单个钱包沉默多久进入宽限期
        uint256 gracePeriod; // 宽限期，过后才归集
        uint256 inheritPeriod; // 全部钱包沉默多久后继承人可领取
        bool coldIncluded; // 继承时是否包含冷钱包（README：冷钱包要用户主动开启）
        bool exists;
    }

    /// @notice 归集地址/继承人修改的生效延迟（README 安全设计：改了要等，防临期钻空子）
    uint256 public immutable CHANGE_DELAY;
    /// @notice 钱包登记簿（同一条链）
    IWalletRegistry public immutable REGISTRY;

    mapping(address => Config) public configs; // owner => 规则
    mapping(address => address) public walletOwner; // wallet => owner（链接时从登记簿核实）
    mapping(address => uint256) public lastActivity; // wallet => 最后活跃时间（回调同步进来）
    mapping(address => address[]) public ownerWallets; // owner => 他链接过的钱包
    mapping(address => mapping(address => bool)) public linked; // owner => wallet => 是否已在 ownerWallets 里
    mapping(address => address[]) public ownerTokens; // owner => 可归集代币清单
    mapping(address => mapping(address => bool)) public tokenAllowed; // owner => token => 是否在清单
    mapping(address => address) public pendingSweepTarget;
    mapping(address => address) public pendingHeir;
    mapping(address => uint256) public pendingEffectiveAt;
    mapping(address => bool) public claimed; // owner => 继承是否已领取

    constructor(IPayable proxy_, address reactive_, uint256 changeDelay_, IWalletRegistry registry_)
        payable
        AbstractCallback(proxy_, reactive_)
    {
        if (address(registry_) == address(0)) revert ZeroAddress();
        CHANGE_DELAY = changeDelay_;
        REGISTRY = registry_;
    }

    // ---------- 用户配置（在目标链上直接调） ----------

    /// @notice 只能配置一次。之后改归集地址 / 继承人：requestConfigChange + applyConfigChange（有等待期）。
    function configure(
        address sweepTarget_,
        address heir_,
        uint256 waitPeriod_,
        uint256 gracePeriod_,
        uint256 inheritPeriod_,
        bool coldIncluded_
    ) external {
        if (configs[msg.sender].exists) revert AlreadyConfigured();
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

    /// @notice 把自己名下的一个钱包链到金库。钱包本人必须先在登记簿里 register(你, 标签)。
    ///         链接动作本身算一次活动，lastActivity 先记为现在，之后靠 onActivity 回调持续同步。
    function linkWallet(address wallet_) external {
        require(configs[msg.sender].exists, "configure first");
        IWalletRegistry.Entry memory e = REGISTRY.getEntry(wallet_);
        if (!e.active || e.owner != msg.sender) revert NotYourWallet();
        if (!linked[msg.sender][wallet_]) {
            linked[msg.sender][wallet_] = true;
            ownerWallets[msg.sender].push(wallet_);
        }
        walletOwner[wallet_] = msg.sender;
        lastActivity[wallet_] = block.timestamp;
        emit WalletLinked(msg.sender, wallet_, e.tag);
    }

    function setTokenAllowed(address token_, bool allowed_) external {
        require(configs[msg.sender].exists, "configure first");
        if (allowed_ && !tokenAllowed[msg.sender][token_]) {
            ownerTokens[msg.sender].push(token_);
        }
        tokenAllowed[msg.sender][token_] = allowed_;
        emit TokenAllowed(msg.sender, token_, allowed_);
    }

    /// @notice 某钱包现在对 owner_ 的标签；不再属于 owner_（移除 / 换主人）返回 255
    function tagOf(address owner_, address wallet_) public view returns (uint8) {
        if (walletOwner[wallet_] != owner_) return TAG_NONE;
        IWalletRegistry.Entry memory e = REGISTRY.getEntry(wallet_);
        if (!e.active || e.owner != owner_) return TAG_NONE;
        return e.tag;
    }

    /// @notice 兼容旧接口：钱包当前标签（以登记簿为准）
    function walletTag(address wallet_) external view returns (uint8) {
        return tagOf(walletOwner[wallet_], wallet_);
    }

    // ---------- 回调入口（只有 Reactive 合约经 Proxy 能进） ----------

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
        uint8 tag = tagOf(owner, wallet_);
        if (owner == address(0) || !cfg.exists || claimed[owner] || tag == TAG_NONE) {
            emit SweepSkipped(wallet_, 0);
            return;
        }
        if (tag != TAG_SWEEPABLE) {
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
    ///         任何一个（仍属于该用户的）钱包最近有活动都会被拒——这是金库自己的最后一道检查。
    function claim(address owner_) external {
        Config memory cfg = configs[owner_];
        if (!cfg.exists) revert NotConfigured();
        if (msg.sender != cfg.heir) revert NotHeir();
        if (claimed[owner_]) revert AlreadyClaimed();
        address[] memory wallets = ownerWallets[owner_];
        for (uint256 i = 0; i < wallets.length; i++) {
            if (tagOf(owner_, wallets[i]) == TAG_NONE) continue; // 已移除 / 已换主人：不算
            if (block.timestamp < lastActivity[wallets[i]] + cfg.inheritPeriod) {
                revert StillActive();
            }
        }
        claimed[owner_] = true;
        for (uint256 i = 0; i < wallets.length; i++) {
            uint8 tag = tagOf(owner_, wallets[i]);
            if (tag == TAG_NONE) continue;
            if (tag == TAG_COLD && !cfg.coldIncluded) continue;
            _claimAll(owner_, wallets[i], cfg.heir); // 主钱包、可归集钱包，以及开启后的冷钱包
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
            uint256 amt = _move(owner_, tokens[i], wallet_, target_);
            if (amt > 0) {
                moved_ += amt;
                emit Swept(wallet_, tokens[i], amt);
            }
        }
    }

    function _claimAll(address owner_, address wallet_, address heir_) internal {
        address[] memory tokens = ownerTokens[owner_];
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amt = _move(owner_, tokens[i], wallet_, heir_);
            if (amt > 0) emit InheritanceClaimed(owner_, wallet_, tokens[i], amt);
        }
    }

    function _move(address owner_, address token_, address from_, address to_) internal returns (uint256) {
        if (!tokenAllowed[owner_][token_]) return 0;
        IERC20 token = IERC20(token_);
        uint256 bal = token.balanceOf(from_);
        if (bal == 0) return 0;
        try token.transferFrom(from_, to_, bal) returns (bool ok) {
            return ok ? bal : 0;
        } catch {
            return 0;
        }
    }
}
