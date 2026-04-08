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
    error AllowlistTooLong(uint256 length, uint256 max);

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
        _checkAllowlistLength(addrs.allowedBuyTokens.length);
        _checkAllowlistLength(addrs.allowedCounterparties.length);
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
        if (!_inList(p.addrs.allowedSellTokens, sellToken)) return false;
        if (!_inList(p.addrs.allowedBuyTokens, buyToken)) return false;
        if (p.config.maxSellAmountPerTrade != 0 && amount > p.config.maxSellAmountPerTrade) {
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

    function _checkAllowlistLength(uint256 length) private pure {
        if (length > MAX_ALLOWLIST_LENGTH) {
            revert AllowlistTooLong(length, MAX_ALLOWLIST_LENGTH);
        }
    }
}
