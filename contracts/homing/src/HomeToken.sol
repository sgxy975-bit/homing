// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title HomeToken (HMT) — Homing 演示用的测试币（只在测试网用）
/// @notice 任何人都能 mint，只为了演示「被遗忘的钱包里有币 → 被归集回家」。
contract HomeToken {
    string public constant name = "Homing Demo Token";
    string public constant symbol = "HMT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to_, uint256 amount_) external {
        totalSupply += amount_;
        balanceOf[to_] += amount_;
        emit Transfer(address(0), to_, amount_);
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _move(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 a = allowance[from_][msg.sender];
        require(a >= amount_, "allowance");
        if (a != type(uint256).max) allowance[from_][msg.sender] = a - amount_;
        _move(from_, to_, amount_);
        return true;
    }

    function _move(address from_, address to_, uint256 amount_) internal {
        require(balanceOf[from_] >= amount_, "balance");
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }
}
