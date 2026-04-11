// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/PolicyRegistry.sol";
import "../src/types/MoltTradeTypes.sol";

contract PolicyRegistryTest is Test {
    uint256 private constant MAX_ALLOWLIST_LENGTH = 20;

    PolicyRegistry registry;
    address owner = address(0xA1);
    address agent = address(0xA2);
    address tokenA = address(0xB1);
    address tokenB = address(0xB2);
    address counterparty = address(0xC1);

    function setUp() public {
        registry = new PolicyRegistry();
    }

    function _defaultConfig() internal view returns (PolicyConfig memory) {
        return PolicyConfig({agent: agent, validUntil: uint64(block.timestamp + 1 days)});
    }

    function _defaultAddrs() internal view returns (PolicyAddresses memory) {
        address[] memory sell = new address[](1);
        sell[0] = tokenA;
        uint256[] memory sellCaps = new uint256[](1);
        sellCaps[0] = 1000e18;
        address[] memory buy = new address[](1);
        buy[0] = tokenB;
        address[] memory cp = new address[](0);
        return PolicyAddresses({
            allowedSellTokens: sell,
            maxSellAmountsPerToken: sellCaps,
            allowedBuyTokens: buy,
            allowedCounterparties: cp
        });
    }

    function test_setPolicy_registersAgent() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        assertEq(registry.activeAgent(owner), agent);
    }

    function test_policyValid_afterSet() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        assertTrue(registry.policyValid(owner));
    }

    function test_policyValid_falseWhenRevoked() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.revokePolicy();
        assertFalse(registry.policyValid(owner));
    }

    function test_policyValid_falseWhenPaused() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.pausePolicy();
        assertFalse(registry.policyValid(owner));
    }

    function test_unpause_restoresValid() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.pausePolicy();
        vm.prank(owner);
        registry.unpausePolicy();
        assertTrue(registry.policyValid(owner));
    }

    function test_policyValid_falseWhenExpired() public {
        vm.prank(owner);
        PolicyConfig memory cfg = _defaultConfig();
        cfg.validUntil = uint64(block.timestamp + 1);
        registry.setPolicy(cfg, _defaultAddrs());
        vm.warp(block.timestamp + 2);
        assertFalse(registry.policyValid(owner));
    }

    function test_policyValid_noExpiry() public {
        vm.prank(owner);
        PolicyConfig memory cfg = _defaultConfig();
        cfg.validUntil = 0;
        registry.setPolicy(cfg, _defaultAddrs());
        vm.warp(block.timestamp + 365 days);
        assertTrue(registry.policyValid(owner));
    }

    function test_checkTrade_allowedTokens() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        assertTrue(registry.checkTrade(owner, tokenA, tokenB, 500e18, counterparty));
    }

    function test_checkTrade_blockedSellToken() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        assertFalse(registry.checkTrade(owner, tokenB, tokenB, 500e18, counterparty));
    }

    function test_checkTrade_blockedBuyToken() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        assertFalse(registry.checkTrade(owner, tokenA, tokenA, 500e18, counterparty));
    }

    function test_checkTrade_amountExceedsCap() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        assertFalse(registry.checkTrade(owner, tokenA, tokenB, 1001e18, counterparty));
    }

    function test_checkTrade_zeroCap_allowsAny() public {
        vm.prank(owner);
        PolicyAddresses memory addrs = _defaultAddrs();
        addrs.maxSellAmountsPerToken[0] = 0;
        registry.setPolicy(_defaultConfig(), addrs);
        assertTrue(registry.checkTrade(owner, tokenA, tokenB, type(uint256).max, counterparty));
    }

    function test_checkTrade_usesPerTokenCaps() public {
        address[] memory sell = new address[](2);
        sell[0] = tokenA;
        sell[1] = tokenB;
        uint256[] memory sellCaps = new uint256[](2);
        sellCaps[0] = 100;
        sellCaps[1] = 50;
        address[] memory buy = new address[](2);
        buy[0] = tokenB;
        buy[1] = tokenA;
        address[] memory cp = new address[](0);

        vm.prank(owner);
        registry.setPolicy(
            _defaultConfig(),
            PolicyAddresses({
                allowedSellTokens: sell,
                maxSellAmountsPerToken: sellCaps,
                allowedBuyTokens: buy,
                allowedCounterparties: cp
            })
        );

        assertTrue(registry.checkTrade(owner, tokenA, tokenB, 75, counterparty));
        assertFalse(registry.checkTrade(owner, tokenB, tokenA, 75, counterparty));
    }

    function test_checkTrade_specificCounterparty_allowed() public {
        address[] memory sell = new address[](1);
        sell[0] = tokenA;
        address[] memory buy = new address[](1);
        buy[0] = tokenB;
        address[] memory cp = new address[](1);
        cp[0] = counterparty;
        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: sell,
            maxSellAmountsPerToken: _defaultAddrs().maxSellAmountsPerToken,
            allowedBuyTokens: buy,
            allowedCounterparties: cp
        });
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), addrs);
        assertTrue(registry.checkTrade(owner, tokenA, tokenB, 500e18, counterparty));
    }

    function test_checkTrade_specificCounterparty_blocked() public {
        address[] memory sell = new address[](1);
        sell[0] = tokenA;
        address[] memory buy = new address[](1);
        buy[0] = tokenB;
        address[] memory cp = new address[](1);
        cp[0] = counterparty;
        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: sell,
            maxSellAmountsPerToken: _defaultAddrs().maxSellAmountsPerToken,
            allowedBuyTokens: buy,
            allowedCounterparties: cp
        });
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), addrs);
        assertFalse(registry.checkTrade(owner, tokenA, tokenB, 500e18, address(0xDEAD)));
    }

    function test_checkTrade_falseWhenPolicyInvalid() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.revokePolicy();
        assertFalse(registry.checkTrade(owner, tokenA, tokenB, 500e18, counterparty));
    }

    function test_revokePolicy_cannotUnpause() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.revokePolicy();
        vm.prank(owner);
        vm.expectRevert();
        registry.unpausePolicy();
    }

    function test_noPriorPolicy_policyValidFalse() public {
        assertFalse(registry.policyValid(owner));
    }

    function test_setPolicy_zeroAgent_reverts() public {
        PolicyConfig memory cfg = _defaultConfig();
        cfg.agent = address(0);
        vm.prank(owner);
        vm.expectRevert();
        registry.setPolicy(cfg, _defaultAddrs());
    }

    function test_revokePolicy_noPolicySet_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.revokePolicy();
    }

    function test_pausePolicy_noPolicySet_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.pausePolicy();
    }

    function test_activeAgent_returnsZeroWhenPaused() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.pausePolicy();
        assertEq(registry.activeAgent(owner), address(0));
    }

    function test_activeAgent_returnsZeroWhenExpired() public {
        vm.prank(owner);
        PolicyConfig memory cfg = _defaultConfig();
        cfg.validUntil = uint64(block.timestamp + 1);
        registry.setPolicy(cfg, _defaultAddrs());
        vm.warp(block.timestamp + 2);
        assertEq(registry.activeAgent(owner), address(0));
    }

    function test_revokePolicy_alreadyRevoked_reverts() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.revokePolicy();
        vm.prank(owner);
        vm.expectRevert();
        registry.revokePolicy();
    }

    function test_pausePolicy_alreadyPaused_reverts() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.pausePolicy();
        vm.prank(owner);
        vm.expectRevert();
        registry.pausePolicy();
    }

    function test_unpausePolicy_notPaused_reverts() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        // Policy is active (never paused) — unpause must revert and must NOT rotate policyNonce
        uint256 nonceBefore = registry.policyNonce(owner);
        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.NotPaused.selector);
        registry.unpausePolicy();
        assertEq(registry.policyNonce(owner), nonceBefore);
    }

    function test_pausePolicy_revoked_revertsWithoutRotatingNonce() public {
        vm.prank(owner);
        registry.setPolicy(_defaultConfig(), _defaultAddrs());
        vm.prank(owner);
        registry.revokePolicy();

        uint256 nonceBefore = registry.policyNonce(owner);

        vm.prank(owner);
        vm.expectRevert(PolicyRegistry.AlreadyRevoked.selector);
        registry.pausePolicy();

        assertEq(registry.policyNonce(owner), nonceBefore);
    }

    function test_setPolicy_revertsWhenSellAllowlistTooLong() public {
        address[] memory sell = new address[](MAX_ALLOWLIST_LENGTH + 1);
        uint256[] memory sellCaps = new uint256[](MAX_ALLOWLIST_LENGTH + 1);
        for (uint256 i = 0; i < sell.length; i++) {
            sell[i] = address(uint160(0x1000 + i));
            sellCaps[i] = 1000e18;
        }

        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: sell,
            maxSellAmountsPerToken: sellCaps,
            allowedBuyTokens: _defaultAddrs().allowedBuyTokens,
            allowedCounterparties: _defaultAddrs().allowedCounterparties
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.AllowlistTooLong.selector, sell.length, MAX_ALLOWLIST_LENGTH
            )
        );
        registry.setPolicy(_defaultConfig(), addrs);
    }

    function test_setPolicy_revertsWhenBuyAllowlistTooLong() public {
        address[] memory buy = new address[](MAX_ALLOWLIST_LENGTH + 1);
        for (uint256 i = 0; i < buy.length; i++) {
            buy[i] = address(uint160(0x2000 + i));
        }

        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: _defaultAddrs().allowedSellTokens,
            maxSellAmountsPerToken: _defaultAddrs().maxSellAmountsPerToken,
            allowedBuyTokens: buy,
            allowedCounterparties: _defaultAddrs().allowedCounterparties
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.AllowlistTooLong.selector, buy.length, MAX_ALLOWLIST_LENGTH
            )
        );
        registry.setPolicy(_defaultConfig(), addrs);
    }

    function test_setPolicy_revertsWhenCounterpartyAllowlistTooLong() public {
        address[] memory cp = new address[](MAX_ALLOWLIST_LENGTH + 1);
        for (uint256 i = 0; i < cp.length; i++) {
            cp[i] = address(uint160(0x3000 + i));
        }

        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: _defaultAddrs().allowedSellTokens,
            maxSellAmountsPerToken: _defaultAddrs().maxSellAmountsPerToken,
            allowedBuyTokens: _defaultAddrs().allowedBuyTokens,
            allowedCounterparties: cp
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.AllowlistTooLong.selector, cp.length, MAX_ALLOWLIST_LENGTH
            )
        );
        registry.setPolicy(_defaultConfig(), addrs);
    }

    function test_setPolicy_revertsWhenSellTokenCapsLengthMismatch() public {
        address[] memory sell = new address[](2);
        sell[0] = tokenA;
        sell[1] = tokenB;
        uint256[] memory sellCaps = new uint256[](1);
        sellCaps[0] = 1000e18;

        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: sell,
            maxSellAmountsPerToken: sellCaps,
            allowedBuyTokens: _defaultAddrs().allowedBuyTokens,
            allowedCounterparties: _defaultAddrs().allowedCounterparties
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyRegistry.SellTokenLimitLengthMismatch.selector, sell.length, sellCaps.length
            )
        );
        registry.setPolicy(_defaultConfig(), addrs);
    }

    function test_setPolicy_revertsWhenSellTokensContainDuplicates() public {
        address[] memory sell = new address[](2);
        sell[0] = tokenA;
        sell[1] = tokenA;
        uint256[] memory sellCaps = new uint256[](2);
        sellCaps[0] = 1000e18;
        sellCaps[1] = 500e18;

        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: sell,
            maxSellAmountsPerToken: sellCaps,
            allowedBuyTokens: _defaultAddrs().allowedBuyTokens,
            allowedCounterparties: _defaultAddrs().allowedCounterparties
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PolicyRegistry.DuplicateSellToken.selector, tokenA));
        registry.setPolicy(_defaultConfig(), addrs);
    }
}
