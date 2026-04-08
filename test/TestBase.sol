// SPDX-License-Identifier: MPL-2.0
pragma solidity ^0.8.24;

interface Vm {
    function expectRevert(bytes4 revertData) external;

    function expectRevert(bytes calldata revertData) external;

    function prank(address msgSender) external;

    function startPrank(address msgSender) external;

    function stopPrank() external;

    function warp(uint256 newTimestamp) external;
}

contract TestBase {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(address left, address right, string memory message) internal pure {
        if (left != right) {
            revert(message);
        }
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        if (left != right) {
            revert(message);
        }
    }

    function assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        if (left != right) {
            revert(message);
        }
    }

    function assertEq(bytes memory left, bytes memory right, string memory message) internal pure {
        if (keccak256(left) != keccak256(right)) {
            revert(message);
        }
    }

    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) {
            revert(message);
        }
    }
}
