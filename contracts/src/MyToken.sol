// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title MyToken - Custom Gas Token for L2 Chain
/// @notice ERC-20 token deployed on BSC L1, used as native gas token on the L2 via OP Stack CGT v2.
/// @dev Compliant with CGT v2 requirements:
///      - Standard ERC-20 (no transfer hooks, no rebasing, no transfer fees)
///      - Exactly 18 decimals
///      - name() and symbol() each <= 32 bytes
contract MyToken {
    string public constant name = "Matrix AI Network";
    string public constant symbol = "MAN";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "MyToken: caller is not the owner");
        _;
    }

    constructor(uint256 initialSupply, address initialHolder) {
        require(initialHolder != address(0), "MyToken: zero address");
        owner = msg.sender;
        _mint(initialHolder, initialSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "MyToken: insufficient allowance");
            unchecked {
                _approve(from, msg.sender, currentAllowance - amount);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "MyToken: zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "MyToken: transfer from zero address");
        require(to != address(0), "MyToken: transfer to zero address");
        require(balanceOf[from] >= amount, "MyToken: insufficient balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "MyToken: mint to zero address");
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MyToken: burn exceeds balance");
        unchecked {
            balanceOf[from] -= amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner != address(0), "MyToken: approve from zero address");
        require(spender != address(0), "MyToken: approve to zero address");
        allowance[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }
}
