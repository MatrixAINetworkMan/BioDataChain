// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20Base} from "./ERC20Base.sol";

/// @title TestERC20 - a freely mintable ERC-20 for exercising the DEX on testnets.
/// @notice Anyone can `mint` so testers can grab tokens without a faucet. DEV/TEST ONLY.
contract TestERC20 is ERC20Base {
    constructor(string memory _name, string memory _symbol, uint256 initialSupply)
        ERC20Base(_name, _symbol)
    {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
