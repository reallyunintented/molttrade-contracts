// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

/// @notice Owner-registered policy binding an agent to trading rules.
struct PolicyConfig {
    address agent;
    uint64 validUntil; // unix timestamp; 0 = no expiry
}

/// @notice Allowlist addresses attached to a policy.
struct PolicyAddresses {
    address[] allowedSellTokens;
    uint256[] maxSellAmountsPerToken; // 0 = no cap for the corresponding sell token
    address[] allowedBuyTokens;
    /// @dev Empty = open to any counterparty.
    address[] allowedCounterparties;
}

/// @notice A single side of a proposed bilateral trade, signed by the owner's agent.
struct SettlementIntent {
    address owner; // whose wallet is debited
    address sellToken;
    uint256 sellAmount; // gross amount pulled from owner's wallet
    address buyToken;
    uint256 minBuyAmount; // minimum net amount acceptable after protocol fee / token transfer effects
    address counterparty; // expected other owner; address(0) not permitted
    uint256 nonce; // per-owner replay protection
    uint256 deadline; // unix timestamp
    uint256 policyNonce; // must match registry.policyNonce(owner) at settle time
    uint256 feeBps; // settlement fee config snapshot, capped onchain
    address feeRecipient; // settlement fee recipient snapshot
}
