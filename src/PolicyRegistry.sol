// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "./interfaces/IPolicyRegistry.sol";
import "./types/MoltTradeTypes.sol";

contract PolicyRegistry is IPolicyRegistry {
    error NoPolicySet();
    error AlreadyRevoked();
    error AlreadyPaused();
    error NotPaused();
    error ZeroAgent();
    error ZeroAddressInAllowlist();
    error AllowlistTooLong(uint256 length, uint256 max);
    error SellTokenLimitLengthMismatch(uint256 tokenCount, uint256 capCount);
    error DuplicateSellToken(address token);

    uint256 public constant MAX_ALLOWLIST_LENGTH = 20;

    struct StoredPolicy {
        PolicyConfig config;
        PolicyAddresses addrs;
        bool isRevoked;
        bool isPaused;
        bool exists;
    }

    mapping(address => StoredPolicy) private _policies;
    mapping(address => uint256) public policyNonce;

    function setPolicy(PolicyConfig calldata config, PolicyAddresses calldata addrs) external {
        if (config.agent == address(0)) revert ZeroAgent();
        _checkAllowlistLength(addrs.allowedSellTokens.length);
        if (addrs.allowedSellTokens.length != addrs.maxSellAmountsPerToken.length) {
            revert SellTokenLimitLengthMismatch(
                addrs.allowedSellTokens.length, addrs.maxSellAmountsPerToken.length
            );
        }
        _checkAllowlistLength(addrs.allowedBuyTokens.length);
        _checkAllowlistLength(addrs.allowedCounterparties.length);
        _checkNoZeroAddresses(addrs.allowedSellTokens);
        _checkNoZeroAddresses(addrs.allowedBuyTokens);
        _checkNoZeroAddresses(addrs.allowedCounterparties);
        _checkDuplicateSellTokens(addrs.allowedSellTokens);
        policyNonce[msg.sender]++;
        // Intentionally overwrites any prior policy including revoked ones.
        // Revocation is not permanent: owners can re-register to resume delegation.
        _policies[msg.sender] = StoredPolicy({
            config: config, addrs: addrs, isRevoked: false, isPaused: false, exists: true
        });
        emit PolicySet(msg.sender, config.agent, config.validUntil);
    }

    function revokePolicy() external {
        StoredPolicy storage p = _policies[msg.sender];
        if (!p.exists) revert NoPolicySet();
        if (p.isRevoked) revert AlreadyRevoked();
        p.isRevoked = true;
        emit PolicyRevoked(msg.sender);
    }

    function pausePolicy() external {
        StoredPolicy storage p = _policies[msg.sender];
        if (!p.exists) revert NoPolicySet();
        if (p.isRevoked) revert AlreadyRevoked();
        if (p.isPaused) revert AlreadyPaused();
        policyNonce[msg.sender]++;
        p.isPaused = true;
        emit PolicyPaused(msg.sender);
    }

    function unpausePolicy() external {
        StoredPolicy storage p = _policies[msg.sender];
        if (!p.exists) revert NoPolicySet();
        if (p.isRevoked) revert AlreadyRevoked();
        if (!p.isPaused) revert NotPaused();
        policyNonce[msg.sender]++;
        p.isPaused = false;
        emit PolicyUnpaused(msg.sender);
    }

    function activeAgent(address owner) external view returns (address) {
        StoredPolicy storage p = _policies[owner];
        if (!p.exists || p.isRevoked || p.isPaused) return address(0);
        if (p.config.validUntil != 0 && block.timestamp > p.config.validUntil) return address(0);
        return p.config.agent;
    }

    function policyValid(address owner) external view returns (bool) {
        StoredPolicy storage p = _policies[owner];
        if (!p.exists || p.isRevoked || p.isPaused) return false;
        if (p.config.validUntil != 0 && block.timestamp > p.config.validUntil) return false;
        return true;
    }

    function checkTrade(
        address owner,
        address sellToken,
        address buyToken,
        uint256 amount,
        address counterparty
    ) external view returns (bool) {
        StoredPolicy storage p = _policies[owner];
        if (!p.exists || p.isRevoked || p.isPaused) return false;
        if (p.config.validUntil != 0 && block.timestamp > p.config.validUntil) return false;
        bool sellTokenAllowed;
        uint256 sellTokenCap;
        (sellTokenAllowed, sellTokenCap) = _sellTokenPolicy(p.addrs, sellToken);
        if (!sellTokenAllowed) return false;
        if (!_inList(p.addrs.allowedBuyTokens, buyToken)) return false;
        if (sellTokenCap != 0 && amount > sellTokenCap) {
            return false;
        }
        if (
            p.addrs.allowedCounterparties.length > 0
                && !_inList(p.addrs.allowedCounterparties, counterparty)
        ) {
            return false;
        }
        return true;
    }

    function _inList(address[] storage list, address target) private view returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == target) return true;
        }
        return false;
    }

    function _sellTokenPolicy(PolicyAddresses storage addrs, address sellToken)
        private
        view
        returns (bool allowed, uint256 cap)
    {
        for (uint256 i = 0; i < addrs.allowedSellTokens.length; i++) {
            if (addrs.allowedSellTokens[i] == sellToken) {
                return (true, addrs.maxSellAmountsPerToken[i]);
            }
        }
        return (false, 0);
    }

    function _checkAllowlistLength(uint256 length) private pure {
        if (length > MAX_ALLOWLIST_LENGTH) {
            revert AllowlistTooLong(length, MAX_ALLOWLIST_LENGTH);
        }
    }

    function _checkDuplicateSellTokens(address[] calldata sellTokens) private pure {
        for (uint256 i = 0; i < sellTokens.length; i++) {
            for (uint256 j = i + 1; j < sellTokens.length; j++) {
                if (sellTokens[i] == sellTokens[j]) {
                    revert DuplicateSellToken(sellTokens[i]);
                }
            }
        }
    }

    /// @dev Rejects address(0) in any allowlist. A zero-address sell token would
    /// otherwise silently no-op through SafeToken (raw call to address(0) returns
    /// success with empty returndata), and a zero counterparty would be
    /// unreachable anyway since BilateralSettlement rejects it in `settle`.
    function _checkNoZeroAddresses(address[] calldata list) private pure {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == address(0)) revert ZeroAddressInAllowlist();
        }
    }
}
