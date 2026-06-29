// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice 极简 ERC-20，仅供 tokenspammer 压测用。
/// 构造时把全部 supply 一次性 mint 给 _to（部署者），无 mint() / burn() / owner，
/// 字节码尽量小以减少部署 gas。
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _initialSupply, address _to) {
        name = _name;
        symbol = _symbol;
        totalSupply = _initialSupply;
        balanceOf[_to] = _initialSupply;
        emit Transfer(address(0), _to, _initialSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            unchecked { allowance[from][msg.sender] = a - amount; }
        }
        require(balanceOf[from] >= amount, "balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }
}
