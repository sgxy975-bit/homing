// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Homing 三方接口约定（v0.3：已和 bee 的 WalletRegistry.sol / Vault.sol 对齐，待 bee / 方瑜 确认后定死）
/// @notice 这个文件是「合同」：登记簿发什么事件、金库收什么回调，全写在这里。
///         任何一方要改，先改这个文件、群里说一声，另外两方再跟着改。

/// 钱包标签
///   0 = PRIMARY    日常钱包：证明「人还在」，也是归集目的地，永不被归集
///   1 = COLD       冷钱包：永不被归集（遗产流程以后再说）
///   2 = SWEEPABLE  可归集：闲置超过 idleSeconds 就把余额归集回主钱包

/// @notice 登记簿（Registry，部署在 Sepolia）发出的事件。Reactive 合约订阅它。
///         三个 indexed 字段 = topic1/2/3，Reactive 可以直接读，不用解码 data。
interface IHomingRegistryEvents {
    // 以 bee 已部署的登记簿为准（Sepolia 0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6）
    event WalletAdded(
        address indexed wallet,  // topic1：被登记的钱包
        address indexed owner,   // topic2：这组钱包的主人（主钱包）
        uint8 tag                // data：0/1/2，见上
    );
    // 没有 chainId：同一地址在所有 EVM 链上相同，Reactive 同时盯 Sepolia + Base Sepolia。
    // 没有 idleSeconds：闲置时长由 Reactive 统一设置（演示 300 秒）；金库自己也有一份阈值做双保险。
}

/// @notice 金库（Vault，bee，部署在 Sepolia）的两个回调 —— 以 bee 的 Vault.sol 为准。
///         第一个参数 rvm 由网络自动填成 Reactive 合约地址，金库用
///         onlyServiceProvider + onlyCallbackSender(rvm) 鉴权。
///         第 2、3 个参数 = 触发这次回调的事件所在链 chainId 和交易哈希（便于追溯，金库不使用）。
interface IHomingVault {
    /// @notice 某个已登记钱包有转出交易 → 金库把 lastActivity 往前推（旧数据不会把时间往回拨）
    function onActivity(address rvm, uint256 chainId, uint256 txHash, address wallet, uint256 lastActivity) external;

    /// @notice Reactive 认为这个钱包闲置太久 → 请金库归集。
    ///         金库按用户自己配置的 waitPeriod + gracePeriod 复核，没到期只发 SweepSkipped，不 revert。
    function onSweep(address rvm, uint256 chainId, uint256 txHash, address wallet) external;
}

/// 登记簿的另外两个事件（Reactive 也监听，保持标签同步）
interface IHomingRegistryMoreEvents {
    event WalletTagChanged(address indexed wallet, uint8 tag);
    event WalletRemoved(address indexed wallet);
}
