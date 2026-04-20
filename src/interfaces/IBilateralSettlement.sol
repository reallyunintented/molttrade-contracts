// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "../types/MoltTradeTypes.sol";

interface IBilateralSettlement {
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferCanceled(address indexed owner, address indexed previousPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ContractPaused(address indexed caller);
    event ContractUnpaused(address indexed caller);
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
    event NonceCancelled(address indexed owner, uint256 cancelledNonce);

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

    /// @notice Address that must call `acceptOwnership` to finalize a pending
    /// ownership transfer, or `address(0)` if none is pending.
    function pendingOwner() external view returns (address);

    /// @notice Whether new settlements are currently paused.
    function paused() external view returns (bool);

    /// @notice Begin a two-step ownership transfer by setting `pendingOwner`.
    /// Pass `address(0)` to cancel a pending transfer.
    function transferOwnership(address newOwner) external;

    /// @notice Finalize a two-step ownership transfer. Callable only by the
    /// current `pendingOwner`.
    function acceptOwnership() external;

    /// @notice Current protocol fee in basis points for newly quoted settlements.
    function feeBps() external view returns (uint256);

    /// @notice Current protocol fee recipient for newly quoted settlements.
    function feeRecipient() external view returns (address);

    /// @notice Update fee config for future settlements.
    function setFee(uint256 bps, address recipient) external;

    /// @notice Burn the caller's next intent nonce. Lets an owner invalidate a
    /// single in-flight intent without revoking or pausing the policy.
    function cancelNonce() external;

    /// @notice Pause new settlements until `unpause` is called.
    function pause() external;

    /// @notice Resume new settlements after a pause.
    function unpause() external;
}
