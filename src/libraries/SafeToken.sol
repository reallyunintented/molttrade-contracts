// SPDX-License-Identifier: MPL-2.0
pragma solidity ^0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";

library SafeToken {
    error TokenOperationFailed(address token, bytes data);

    function balanceOf(address token, address account) internal view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool success, bytes memory returndata) = token.call(data);
        if (!success) {
            revert TokenOperationFailed(token, data);
        }

        if (returndata.length > 0 && !abi.decode(returndata, (bool))) {
            revert TokenOperationFailed(token, data);
        }
    }
}
