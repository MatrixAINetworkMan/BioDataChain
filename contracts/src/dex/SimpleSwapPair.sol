// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20Base} from "./ERC20Base.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SimpleSwapPair - a minimal Uniswap-V2-style constant-product AMM for a single token pair.
/// @notice The contract IS the LP token (mints/burns shares to liquidity providers).
///         Reserves follow x * y = k with a 0.3% swap fee. Dependency-free and self-contained.
/// @dev Intentionally simple for testing a chain end-to-end (deploy / add liquidity / swap).
///      Not audited; do not use with real value.
contract SimpleSwapPair is ERC20Base {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;

    uint256 private unlocked = 1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    modifier lock() {
        require(unlocked == 1, "LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor(address _token0, address _token1) ERC20Base("SimpleSwap LP", "SS-LP") {
        require(_token0 != _token1, "IDENTICAL_TOKENS");
        require(_token0 != address(0) && _token1 != address(0), "ZERO_ADDRESS");
        // Order tokens deterministically (Uniswap convention).
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    /// @notice Deposit token0/token1 already transferred in and mint LP shares.
    /// @dev Caller (or a router) must transfer the input tokens to this contract before calling.
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        uint256 balance0 = IERC20Minimal(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY
        } else {
            uint256 l0 = (amount0 * _totalSupply) / _reserve0;
            uint256 l1 = (amount1 * _totalSupply) / _reserve1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Burn LP shares (already transferred in) and withdraw the underlying tokens.
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = IERC20Minimal(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply;
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        IERC20Minimal(token0).transfer(to, amount0);
        IERC20Minimal(token1).transfer(to, amount1);

        balance0 = IERC20Minimal(token0).balanceOf(address(this));
        balance1 = IERC20Minimal(token1).balanceOf(address(this));
        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Constant-product swap. Input tokens must be transferred in before calling.
    /// @dev Enforces (balance0Adj * balance1Adj) >= reserve0 * reserve1 * 1e6 with a 0.3% fee.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external lock {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT");
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");
        require(to != token0 && to != token1, "INVALID_TO");

        if (amount0Out > 0) IERC20Minimal(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20Minimal(token1).transfer(to, amount1Out);

        uint256 balance0 = IERC20Minimal(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT");

        // Apply 0.3% fee: adjusted balance = balance*1000 - amountIn*3
        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(
            balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * (1000 * 1000),
            "K"
        );

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Pure helper: output amount for a given input given reserves (0.3% fee).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "OVERFLOW");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(reserve0, reserve1);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
