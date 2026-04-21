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

    struct SellTokenPolicy {
        bool allowed;
        uint256 cap; // 0 = no cap when allowed
    }

    struct StoredPolicy {
        PolicyConfig config;
        bool isRevoked;
        bool isPaused;
        bool exists;
        // Bumped on every setPolicy. Allowlist mappings are keyed on this so a
        // fresh policy starts with empty lookups without paying to clear the old.
        uint64 version;
        // 0 means the counterparty allowlist is open (any counterparty allowed).
        uint64 counterpartyCount;
    }

    mapping(address => StoredPolicy) private _policies;
    mapping(address => uint256) public policyNonce;

    // owner => version => token => SellTokenPolicy
    mapping(address => mapping(uint64 => mapping(address => SellTokenPolicy))) private
        _sellTokenPolicies;
    // owner => version => token => allowed
    mapping(address => mapping(uint64 => mapping(address => bool))) private _buyTokenAllowed;
    // owner => version => counterparty => allowed
    mapping(address => mapping(uint64 => mapping(address => bool))) private _counterpartyAllowed;

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

        StoredPolicy storage p = _policies[msg.sender];
        // Bump version. Old allowlist mapping entries remain in storage but are
        // unreachable because every read uses the new version key.
        uint64 newVersion = p.version + 1;
        p.config = config;
        p.isRevoked = false;
        p.isPaused = false;
        p.exists = true;
        p.version = newVersion;
        p.counterpartyCount = uint64(addrs.allowedCounterparties.length);

        for (uint256 i = 0; i < addrs.allowedSellTokens.length; i++) {
            _sellTokenPolicies[msg.sender][newVersion][addrs.allowedSellTokens[i]] =
                SellTokenPolicy({ allowed: true, cap: addrs.maxSellAmountsPerToken[i] });
        }
        for (uint256 i = 0; i < addrs.allowedBuyTokens.length; i++) {
            _buyTokenAllowed[msg.sender][newVersion][addrs.allowedBuyTokens[i]] = true;
        }
        for (uint256 i = 0; i < addrs.allowedCounterparties.length; i++) {
            _counterpartyAllowed[msg.sender][newVersion][addrs.allowedCounterparties[i]] = true;
        }

        emit PolicySet(msg.sender, config.agent, config.validUntil);
    }

    function revokePolicy() external {
        StoredPolicy storage p = _policies[msg.sender];
        if (!p.exists) revert NoPolicySet();
        if (p.isRevoked) revert AlreadyRevoked();
        policyNonce[msg.sender]++;
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

        uint64 version = p.version;
        SellTokenPolicy storage stp = _sellTokenPolicies[owner][version][sellToken];
        if (!stp.allowed) return false;
        if (stp.cap != 0 && amount > stp.cap) return false;
        if (!_buyTokenAllowed[owner][version][buyToken]) return false;
        if (p.counterpartyCount > 0 && !_counterpartyAllowed[owner][version][counterparty]) {
            return false;
        }
        return true;
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
