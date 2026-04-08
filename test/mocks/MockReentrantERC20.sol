// SPDX-License-Identifier: MPL-2.0
pragma solidity ^0.8.24;

import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @notice ERC20 that calls a stored settlement payload on first transferFrom.
/// Used to verify the nonReentrant guard on BilateralSettlement.settle().
contract MockReentrantERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    address public immutable settlement;
    bytes public attackCalldata;
    bool private _attacking;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address settlement_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        settlement = settlement_;
    }

    function setAttackCalldata(bytes calldata data) external {
        attackCalldata = data;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        // Fire reentrant call on first transferFrom only; propagate any revert
        if (!_attacking && attackCalldata.length > 0) {
            _attacking = true;
            (bool ok, bytes memory data) = settlement.call(attackCalldata);
            _attacking = false;
            if (!ok) assembly { revert(add(data, 32), mload(data)) }
        }

        return true;
    }
}
