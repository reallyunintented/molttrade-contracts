// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "../types/MoltTradeTypes.sol";

interface IBilateralSettlement {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Settled(
        address indexed ownerA,
        address indexed ownerB,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 feeAmountA,
        uint256 feeAmountB,
        address feeRecipient,
        uint256 feeBps
    );
    event FeeUpdated(uint256 feeBps, address feeRecipient);

    /// @notice Atomically settle a matched pair of signed intents.
    function settle(
        SettlementIntent calldata intentA,
        bytes calldata sigA,
        SettlementIntent calldata intentB,
        bytes calldata sigB
    ) external;

    /// @notice Per-owner nonce for replay protection.
    function nonces(address owner) external view returns (uint256);

    /// @notice EIP-712 digest of a SettlementIntent, used by agents when signing.
    function intentDigest(SettlementIntent calldata intent) external view returns (bytes32);

    /// @notice Protocol fee owner. Can update fee params.
    function owner() external view returns (address);

    /// @notice Transfer protocol fee ownership to a new admin address.
    function transferOwnership(address newOwner) external;

    /// @notice Current protocol fee in basis points for newly quoted settlements.
    function feeBps() external view returns (uint256);

    /// @notice Current protocol fee recipient for newly quoted settlements.
    function feeRecipient() external view returns (address);

    /// @notice Update fee config for future settlements.
    function setFee(uint256 bps, address recipient) external;
}
