// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title WalletRegistry — bee 的钱包登记簿（源链）
/// @notice Homing 的链路源头：用户把自己的每个钱包登记进来并打标签。
///         登记时发出 WalletAdded 事件，Yilin 的 Reactive 合约订阅它，
///         随即动态订阅这个钱包的代币 Transfer 活动——所以 WalletAdded 的
///         字段是开工第一天必须和 Yilin 定死的接口。
/// @dev 简化说明：MVP 里由钱包本人调用 register（这本身就是“钱包签名添加”）；
///      真实版可改成主钱包拿 EIP-712 签名代其他钱包登记，事件字段不变。
contract WalletRegistry {
    event WalletAdded(address indexed wallet, address indexed owner, uint8 tag);
    event WalletTagChanged(address indexed wallet, uint8 tag);
    event WalletRemoved(address indexed wallet);

    // 钱包标签（Homing README 的三类）
    uint8 public constant TAG_PRIMARY = 0; // 日常钱包：算作“还活着”的信号，也是归集目的地
    uint8 public constant TAG_COLD = 1; // 冷钱包：永不自动归集，只有继承步骤（且用户开启）能动
    uint8 public constant TAG_SWEEPABLE = 2; // 可归集：沉默满期后可归集到日常钱包

    struct Entry {
        address owner; // 主用户（日常钱包所属的人）
        uint8 tag;
        bool active;
    }

    mapping(address => Entry) public entries;

    /// @notice 钱包本人来登记：声明它属于哪个主用户、打什么标签
    function register(address owner_, uint8 tag_) external {
        require(owner_ != address(0), "zero owner");
        require(tag_ <= 2, "bad tag");
        require(!entries[msg.sender].active, "already registered");
        entries[msg.sender] = Entry({owner: owner_, tag: tag_, active: true});
        emit WalletAdded(msg.sender, owner_, tag_);
    }

    function setTag(uint8 tag_) external {
        require(entries[msg.sender].active, "not registered");
        require(tag_ <= 2, "bad tag");
        entries[msg.sender].tag = tag_;
        emit WalletTagChanged(msg.sender, tag_);
    }

    function remove() external {
        require(entries[msg.sender].active, "not registered");
        entries[msg.sender].active = false;
        emit WalletRemoved(msg.sender);
    }

    function getEntry(address wallet_) external view returns (Entry memory) {
        return entries[wallet_];
    }
}
