// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice 一次 tx 把同一个 ERC-20 按定额发给 N 个 recipient。
/// 用法：deployer 先 token.approve(this, max)，再调 batchTransferFrom。
/// 单 tx ~30k + N*30k gas（接收方都是新 holder 时），seed 阶段 N=200 为佳。
contract BatchTransfer {
    function batchTransferFrom(
        address token,
        address from,
        address[] calldata recipients,
        uint256 amount
    ) external {
        IERC20 t = IERC20(token);
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; ) {
            require(t.transferFrom(from, recipients[i], amount), "ttf");
            unchecked { ++i; }
        }
    }

    /// @notice 给 N 个地址各转一笔原生 token；msg.value 必须 >= amount * N。
    /// 多余 wei 退还给 caller。seed 阶段给 50k 钱包打 gas 费可省 99% 的 tx 数。
    function batchSendNative(address[] calldata recipients, uint256 amount) external payable {
        uint256 len = recipients.length;
        require(msg.value >= amount * len, "value");
        for (uint256 i = 0; i < len; ) {
            (bool ok, ) = recipients[i].call{value: amount}("");
            require(ok, "send");
            unchecked { ++i; }
        }
        uint256 leftover = msg.value - amount * len;
        if (leftover > 0) {
            (bool ok, ) = msg.sender.call{value: leftover}("");
            require(ok, "refund");
        }
    }
}
