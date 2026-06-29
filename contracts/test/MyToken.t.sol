// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {MyToken} from "../src/MyToken.sol";

contract MyTokenTest is Test {
    MyToken public token;
    address public owner;
    address public holder;
    address public alice;
    address public bob;

    uint256 constant INITIAL_SUPPLY = 2_000_000_000 ether;

    function setUp() public {
        owner = address(this);
        holder = makeAddr("holder");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        token = new MyToken(INITIAL_SUPPLY, holder);
    }

    function test_metadata() public view {
        assertEq(token.name(), "Matrix AI Network");
        assertEq(token.symbol(), "MAN");
        assertEq(token.decimals(), 18);
        assertTrue(bytes(token.name()).length <= 32, "name exceeds 32 bytes");
        assertTrue(bytes(token.symbol()).length <= 32, "symbol exceeds 32 bytes");
    }

    function test_initialSupply() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(holder), INITIAL_SUPPLY);
    }

    function test_transfer() public {
        vm.prank(holder);
        token.transfer(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.balanceOf(holder), INITIAL_SUPPLY - 1000 ether);
    }

    function test_transferFrom() public {
        vm.prank(holder);
        token.approve(alice, 500 ether);

        vm.prank(alice);
        token.transferFrom(holder, bob, 500 ether);
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_revert_transferInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert("MyToken: insufficient balance");
        token.transfer(bob, 1 ether);
    }

    function test_revert_transferFromInsufficientAllowance() public {
        vm.prank(alice);
        vm.expectRevert("MyToken: insufficient allowance");
        token.transferFrom(holder, bob, 1 ether);
    }

    function test_mint() public {
        token.mint(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 1000 ether);
    }

    function test_revert_mintNotOwner() public {
        vm.prank(alice);
        vm.expectRevert("MyToken: caller is not the owner");
        token.mint(alice, 1000 ether);
    }

    function test_burn() public {
        vm.prank(holder);
        token.burn(500 ether);
        assertEq(token.balanceOf(holder), INITIAL_SUPPLY - 500 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 500 ether);
    }

    function test_transferOwnership() public {
        token.transferOwnership(alice);
        assertEq(token.owner(), alice);
    }

    function test_noTransferFee() public {
        uint256 amount = 12345 ether;
        vm.prank(holder);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount, "CGT: transfer must not charge fee");
    }

    function test_approve_maxAllowance_notDecreased() public {
        vm.prank(holder);
        token.approve(alice, type(uint256).max);

        vm.prank(alice);
        token.transferFrom(holder, bob, 100 ether);
        assertEq(token.allowance(holder, alice), type(uint256).max);
    }
}
