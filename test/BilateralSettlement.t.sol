// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/BilateralSettlement.sol";
import "../src/PolicyRegistry.sol";
import "../src/types/MoltTradeTypes.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockFeeOnTransferERC20.sol";
import "./mocks/MockReentrantERC20.sol";

contract BilateralSettlementTest is Test {
    uint256 private constant SECP256K1N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    BilateralSettlement settlement;
    PolicyRegistry registry;
    MockERC20 tokenA;
    MockERC20 tokenB;

    uint256 ownerAKey = 0x1001;
    uint256 ownerBKey = 0x1002;
    uint256 agentAKey = 0x2001;
    uint256 agentBKey = 0x2002;

    address ownerA;
    address ownerB;
    address agentA;
    address agentB;

    function setUp() public {
        ownerA = vm.addr(ownerAKey);
        ownerB = vm.addr(ownerBKey);
        agentA = vm.addr(agentAKey);
        agentB = vm.addr(agentBKey);

        registry = new PolicyRegistry();
        settlement = new BilateralSettlement(address(registry));

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);

        tokenA.mint(ownerA, 10_000e18);
        tokenB.mint(ownerB, 10_000e18);

        vm.prank(ownerA);
        tokenA.approve(address(settlement), type(uint256).max);
        vm.prank(ownerB);
        tokenB.approve(address(settlement), type(uint256).max);

        _setPolicy(ownerA, agentA, address(tokenA), address(tokenB), 0);
        _setPolicy(ownerB, agentB, address(tokenB), address(tokenA), 0);
    }

    function _setPolicy(address owner, address agent, address sell, address buy, uint256 cap)
        internal
    {
        address[] memory s = new address[](1);
        s[0] = sell;
        uint256[] memory sellCaps = new uint256[](1);
        sellCaps[0] = cap;
        address[] memory b = new address[](1);
        b[0] = buy;
        address[] memory cp = new address[](0);
        PolicyConfig memory cfg = PolicyConfig({agent: agent, validUntil: 0});
        PolicyAddresses memory addrs = PolicyAddresses({
            allowedSellTokens: s,
            maxSellAmountsPerToken: sellCaps,
            allowedBuyTokens: b,
            allowedCounterparties: cp
        });
        vm.prank(owner);
        registry.setPolicy(cfg, addrs);
    }

    function _makeIntents(uint256 amtA, uint256 amtB)
        internal
        view
        returns (SettlementIntent memory iA, SettlementIntent memory iB)
    {
        iA = SettlementIntent({
            owner: ownerA,
            sellToken: address(tokenA),
            sellAmount: amtA,
            buyToken: address(tokenB),
            minBuyAmount: amtB,
            counterparty: ownerB,
            nonce: settlement.nonces(ownerA),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerA),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        iB = SettlementIntent({
            owner: ownerB,
            sellToken: address(tokenB),
            sellAmount: amtB,
            buyToken: address(tokenA),
            minBuyAmount: amtA,
            counterparty: ownerA,
            nonce: settlement.nonces(ownerB),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerB),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
    }

    function _sign(SettlementIntent memory intent, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = settlement.intentDigest(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _malleateToHighS(bytes memory signature) internal pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        uint8 altV = v == 27 ? 28 : 27;
        bytes32 highS = bytes32(SECP256K1N - uint256(s));
        return abi.encodePacked(r, highS, altV);
    }

    // ── existing tests ────────────────────────────────────────────────────────

    function test_settle_transfersTokens() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        uint256 preOwnerATokenB = tokenB.balanceOf(ownerA);
        uint256 preOwnerBTokenA = tokenA.balanceOf(ownerB);

        settlement.settle(iA, sA, iB, sB);

        assertEq(tokenB.balanceOf(ownerA), preOwnerATokenB + 200e18);
        assertEq(tokenA.balanceOf(ownerB), preOwnerBTokenA + 100e18);
    }

    function test_setFee_ownerOnly() public {
        vm.prank(ownerA);
        vm.expectRevert(BilateralSettlement.NotOwner.selector);
        settlement.setFee(30, makeAddr("feeRecipient"));
    }

    function test_transferOwnership_ownerOnly() public {
        vm.prank(ownerA);
        vm.expectRevert(BilateralSettlement.NotOwner.selector);
        settlement.transferOwnership(makeAddr("newOwner"));
    }

    function test_transferOwnership_revert_zeroOwner() public {
        vm.expectRevert(BilateralSettlement.ZeroOwner.selector);
        settlement.transferOwnership(address(0));
    }

    function test_transferOwnership_handsOffFeeAdmin() public {
        address newOwner = makeAddr("newOwner");
        address feeRecipient = makeAddr("feeRecipient");

        settlement.transferOwnership(newOwner);

        assertEq(settlement.owner(), newOwner);

        vm.expectRevert(BilateralSettlement.NotOwner.selector);
        settlement.setFee(30, feeRecipient);

        vm.prank(newOwner);
        settlement.setFee(30, feeRecipient);

        assertEq(settlement.feeBps(), 30);
        assertEq(settlement.feeRecipient(), feeRecipient);
    }

    function test_setFee_revert_invalidConfig() public {
        vm.expectRevert(BilateralSettlement.InvalidFeeConfig.selector);
        settlement.setFee(101, makeAddr("feeRecipient"));

        vm.expectRevert(BilateralSettlement.InvalidFeeConfig.selector);
        settlement.setFee(1, address(0));
    }

    function test_settle_protocolFee_succeeds() public {
        address feeCollector = makeAddr("feeCollector");
        settlement.setFee(30, feeCollector); // 0.30%

        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        uint256 feeAmountA = (iA.sellAmount * settlement.feeBps()) / 10_000;
        uint256 feeAmountB = (iB.sellAmount * settlement.feeBps()) / 10_000;
        iA.minBuyAmount = iB.sellAmount - feeAmountB;
        iB.minBuyAmount = iA.sellAmount - feeAmountA;

        settlement.settle(iA, _sign(iA, agentAKey), iB, _sign(iB, agentBKey));

        assertEq(tokenA.balanceOf(ownerB), iA.sellAmount - feeAmountA);
        assertEq(tokenB.balanceOf(ownerA), iB.sellAmount - feeAmountB);
        assertEq(tokenA.balanceOf(feeCollector), feeAmountA);
        assertEq(tokenB.balanceOf(feeCollector), feeAmountB);
    }

    function test_settle_revert_staleFeeConfigAfterUpdate() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        settlement.setFee(30, makeAddr("feeCollector"));

        vm.expectRevert(BilateralSettlement.InvalidFeeConfig.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_protocolFeeAmountNotMet() public {
        settlement.setFee(30, makeAddr("feeCollector"));

        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        vm.expectRevert(BilateralSettlement.AmountNotMet.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_incrementsNonces() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        settlement.settle(iA, _sign(iA, agentAKey), iB, _sign(iB, agentBKey));
        assertEq(settlement.nonces(ownerA), 1);
        assertEq(settlement.nonces(ownerB), 1);
    }

    function test_settle_revert_replayNonce() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        settlement.settle(iA, sA, iB, sB);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_deadlineExpiredA() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iA.deadline = block.timestamp - 1;
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_deadlineExpiredB() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iB.deadline = block.timestamp - 1;
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_badSignatureA() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, ownerAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_badSignatureB() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, ownerBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_highSSignature() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _malleateToHighS(_sign(iA, agentAKey));
        bytes memory sB = _sign(iB, agentBKey);

        vm.expectRevert(BilateralSettlement.BadSignature.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_invalidVSignature() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory goodSigA = _sign(iA, agentAKey);
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(goodSigA, 32))
            s := mload(add(goodSigA, 64))
        }
        bytes memory sA = abi.encodePacked(r, s, uint8(29));
        bytes memory sB = _sign(iB, agentBKey);

        vm.expectRevert(BilateralSettlement.BadSignature.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_zeroAddressRecoverySignature() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));
        bytes memory sB = _sign(iB, agentBKey);

        vm.expectRevert(BilateralSettlement.BadSignature.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_domainSeparator_recomputesOnChainIdChange() public {
        uint256 originalChainId = block.chainid;
        bytes32 separatorBefore = settlement.DOMAIN_SEPARATOR();

        vm.chainId(originalChainId + 1);

        bytes32 separatorAfter = settlement.DOMAIN_SEPARATOR();
        assertNotEq(separatorBefore, separatorAfter);

        vm.chainId(originalChainId);
        assertEq(settlement.DOMAIN_SEPARATOR(), separatorBefore);
    }

    function test_settle_revert_incompatibleTokens() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iB.buyToken = address(tokenB);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_amountNotMet() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iA.minBuyAmount = 300e18;
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_policyRevokedA() public {
        vm.prank(ownerA);
        registry.revokePolicy();
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_policyRevokedB() public {
        vm.prank(ownerB);
        registry.revokePolicy();
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_sellTokenNotAllowedA() public {
        _setPolicy(ownerA, agentA, address(tokenB), address(tokenB), 0);
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_amountExceedsCapA() public {
        _setPolicy(ownerA, agentA, address(tokenA), address(tokenB), 50e18);
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_counterpartyBinding_succeeds() public {
        address[] memory s = new address[](1);
        s[0] = address(tokenA);
        address[] memory b = new address[](1);
        b[0] = address(tokenB);
        address[] memory cp = new address[](1);
        cp[0] = ownerB;
        uint256[] memory sellCaps = new uint256[](1);
        sellCaps[0] = 0;
        vm.prank(ownerA);
        registry.setPolicy(
            PolicyConfig({agent: agentA, validUntil: 0}),
            PolicyAddresses({
                allowedSellTokens: s,
                maxSellAmountsPerToken: sellCaps,
                allowedBuyTokens: b,
                allowedCounterparties: cp
            })
        );
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        // iA.counterparty == ownerB and iB.counterparty == ownerA are set by _makeIntents
        settlement.settle(iA, _sign(iA, agentAKey), iB, _sign(iB, agentBKey));
    }

    function test_settle_revert_counterpartyMismatch() public {
        address[] memory s = new address[](1);
        s[0] = address(tokenA);
        address[] memory b = new address[](1);
        b[0] = address(tokenB);
        address[] memory cp = new address[](1);
        cp[0] = address(0xDEAD);
        uint256[] memory sellCaps = new uint256[](1);
        sellCaps[0] = 0;
        vm.prank(ownerA);
        registry.setPolicy(
            PolicyConfig({agent: agentA, validUntil: 0}),
            PolicyAddresses({
                allowedSellTokens: s,
                maxSellAmountsPerToken: sellCaps,
                allowedBuyTokens: b,
                allowedCounterparties: cp
            })
        );
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    // ── new tests: policyNonce (Fix 1) ────────────────────────────────────────

    function test_policyNonce_incrementsOnSetPolicy() public {
        assertEq(registry.policyNonce(ownerA), 1);
        _setPolicy(ownerA, agentA, address(tokenA), address(tokenB), 0);
        assertEq(registry.policyNonce(ownerA), 2);
    }

    function test_settle_revert_staleIntent_afterRevoke() public {
        // Sign intents at current policyNonce (1)
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        // Revoke and re-register ownerA → policyNonce[ownerA] = 2
        vm.prank(ownerA);
        registry.revokePolicy();
        _setPolicy(ownerA, agentA, address(tokenA), address(tokenB), 0);

        // Old intent (policyNonce=1) must not settle against new registration
        vm.expectRevert(BilateralSettlement.BadNonce.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_stalePolicyNonceA() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iA.policyNonce = 0; // wrong: registry has 1
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.BadNonce.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_stalePolicyNonceB() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iB.policyNonce = 0; // wrong: registry has 1
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.BadNonce.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    // ── new tests: explicit counterparty (Fix 3) ──────────────────────────────

    function test_settle_revert_openCounterpartyA() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iA.counterparty = address(0);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.IncompatibleIntents.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_openCounterpartyB() public {
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        iB.counterparty = address(0);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.IncompatibleIntents.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    // ── new tests: balance delta / fee-on-transfer (Fix 2) ───────────────────

    function test_settle_revert_feeOnTransferTokenA() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("FeeA", "FA", 18, 100); // 1% fee
        feeToken.mint(ownerA, 10_000e18);
        vm.prank(ownerA);
        feeToken.approve(address(settlement), type(uint256).max);

        // Update policies to use feeToken; policyNonce increments to 2 for both
        _setPolicy(ownerA, agentA, address(feeToken), address(tokenB), 0);
        _setPolicy(ownerB, agentB, address(tokenB), address(feeToken), 0);

        SettlementIntent memory iA = SettlementIntent({
            owner: ownerA,
            sellToken: address(feeToken),
            sellAmount: 100e18,
            buyToken: address(tokenB),
            minBuyAmount: 200e18, // gets exactly 200e18 tokenB (no fee)
            counterparty: ownerB,
            nonce: settlement.nonces(ownerA),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerA),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        SettlementIntent memory iB = SettlementIntent({
            owner: ownerB,
            sellToken: address(tokenB),
            sellAmount: 200e18,
            buyToken: address(feeToken),
            minBuyAmount: 100e18, // expects 100e18 but gets 99e18 (1% fee)
            counterparty: ownerA,
            nonce: settlement.nonces(ownerB),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerB),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });

        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.AmountNotMet.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_feeOnTransferTokenB() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("FeeB", "FB", 18, 100); // 1% fee
        feeToken.mint(ownerB, 10_000e18);
        vm.prank(ownerB);
        feeToken.approve(address(settlement), type(uint256).max);

        // Update policies; policyNonce increments to 2 for both
        _setPolicy(ownerA, agentA, address(tokenA), address(feeToken), 0);
        _setPolicy(ownerB, agentB, address(feeToken), address(tokenA), 0);

        SettlementIntent memory iA = SettlementIntent({
            owner: ownerA,
            sellToken: address(tokenA),
            sellAmount: 100e18,
            buyToken: address(feeToken),
            minBuyAmount: 200e18, // expects 200e18 but gets 198e18 (1% of 200e18 burned)
            counterparty: ownerB,
            nonce: settlement.nonces(ownerA),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerA),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        SettlementIntent memory iB = SettlementIntent({
            owner: ownerB,
            sellToken: address(feeToken),
            sellAmount: 200e18,
            buyToken: address(tokenA),
            minBuyAmount: 100e18, // gets exactly 100e18 tokenA (no fee)
            counterparty: ownerA,
            nonce: settlement.nonces(ownerB),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerB),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });

        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.AmountNotMet.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_policyNonce_incrementsOnPause() public {
        assertEq(registry.policyNonce(ownerA), 1);
        vm.prank(ownerA);
        registry.pausePolicy();
        assertEq(registry.policyNonce(ownerA), 2);
    }

    function test_policyNonce_incrementsOnUnpause() public {
        vm.prank(ownerA);
        registry.pausePolicy();
        assertEq(registry.policyNonce(ownerA), 2);
        vm.prank(ownerA);
        registry.unpausePolicy();
        assertEq(registry.policyNonce(ownerA), 3);
    }

    function test_settle_revert_prePauseIntent_afterUnpause() public {
        // Sign with policyNonce=1 (before any pause)
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        // pause → policyNonce=2; unpause → policyNonce=3
        vm.prank(ownerA);
        registry.pausePolicy();
        vm.prank(ownerA);
        registry.unpausePolicy();

        // Pre-pause intent (policyNonce=1) must be dead
        vm.expectRevert(BilateralSettlement.BadNonce.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_intentsSignedDuringPause_afterUnpause() public {
        // Pause ownerA → policyNonce=2
        vm.prank(ownerA);
        registry.pausePolicy();

        // Sign with policyNonce=2 (while paused)
        (SettlementIntent memory iA, SettlementIntent memory iB) = _makeIntents(100e18, 200e18);
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        // Unpause → policyNonce=3; now policyNonce=2 intents are stale
        vm.prank(ownerA);
        registry.unpausePolicy();

        vm.expectRevert(BilateralSettlement.BadNonce.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_sameToken() public {
        // Both intents sell-and-buy the same token (tokenA→tokenA).
        // The existing cross-match checks do NOT fire (tokenA == tokenA → no revert on !=).
        // Only the explicit same-token guard at step 4 catches this.
        // Without that guard the trade would reach checkTrade and revert with
        // PolicyCheckFailed (different selector), so this test is isolated to line 105.
        SettlementIntent memory iA = SettlementIntent({
            owner: ownerA,
            sellToken: address(tokenA),
            sellAmount: 100e18,
            buyToken: address(tokenA),
            minBuyAmount: 100e18,
            counterparty: ownerB,
            nonce: settlement.nonces(ownerA),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerA),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        SettlementIntent memory iB = SettlementIntent({
            owner: ownerB,
            sellToken: address(tokenA),
            sellAmount: 100e18,
            buyToken: address(tokenA),
            minBuyAmount: 100e18,
            counterparty: ownerA,
            nonce: settlement.nonces(ownerB),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerB),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });

        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);
        vm.expectRevert(BilateralSettlement.IncompatibleIntents.selector);
        settlement.settle(iA, sA, iB, sB);
    }

    function test_settle_revert_reentrancy() public {
        MockReentrantERC20 reentrantToken =
            new MockReentrantERC20("ReentrantA", "RA", 18, address(settlement));
        reentrantToken.mint(ownerA, 10_000e18);
        vm.prank(ownerA);
        reentrantToken.approve(address(settlement), type(uint256).max);

        _setPolicy(ownerA, agentA, address(reentrantToken), address(tokenB), 0);
        _setPolicy(ownerB, agentB, address(tokenB), address(reentrantToken), 0);

        uint256 currentPolicyNonceA = registry.policyNonce(ownerA);
        uint256 currentPolicyNonceB = registry.policyNonce(ownerB);

        // Outer intents — nonce 0 (current).
        SettlementIntent memory iA = SettlementIntent({
            owner: ownerA,
            sellToken: address(reentrantToken),
            sellAmount: 100e18,
            buyToken: address(tokenB),
            minBuyAmount: 100e18,
            counterparty: ownerB,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            policyNonce: currentPolicyNonceA,
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        SettlementIntent memory iB = SettlementIntent({
            owner: ownerB,
            sellToken: address(tokenB),
            sellAmount: 100e18,
            buyToken: address(reentrantToken),
            minBuyAmount: 100e18,
            counterparty: ownerA,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            policyNonce: currentPolicyNonceB,
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        bytes memory sA = _sign(iA, agentAKey);
        bytes memory sB = _sign(iB, agentBKey);

        // Attack intents use nonce 1: the outer settle() increments nonces from 0→1
        // before the first token transfer fires. Without the nonReentrant guard the
        // inner call would pass the nonce check and complete a second settlement
        // (double-spend). With the guard it reverts immediately via Reentrancy.
        SettlementIntent memory attackA = SettlementIntent({
            owner: ownerA,
            sellToken: address(reentrantToken),
            sellAmount: 100e18,
            buyToken: address(tokenB),
            minBuyAmount: 100e18,
            counterparty: ownerB,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            policyNonce: currentPolicyNonceA,
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        SettlementIntent memory attackB = SettlementIntent({
            owner: ownerB,
            sellToken: address(tokenB),
            sellAmount: 100e18,
            buyToken: address(reentrantToken),
            minBuyAmount: 100e18,
            counterparty: ownerA,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            policyNonce: currentPolicyNonceB,
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        bytes memory attackSA = _sign(attackA, agentAKey);
        bytes memory attackSB = _sign(attackB, agentBKey);

        reentrantToken.setAttackCalldata(
            abi.encodeCall(settlement.settle, (attackA, attackSA, attackB, attackSB))
        );

        // With guard: inner settle() hits nonReentrant immediately → Reentrancy, propagated
        // by mock, wrapped by SafeToken as TokenOperationFailed → outer settle() reverts.
        // Without guard: inner settle() would complete (nonce=1 matches post-increment state)
        // and the outer call would also complete → vm.expectRevert() would fail, catching
        // the regression.
        vm.expectRevert();
        settlement.settle(iA, sA, iB, sB);
    }

    function test_intentDigest_matchesExpected() public view {
        (SettlementIntent memory iA,) = _makeIntents(100e18, 200e18);

        bytes32 typeHash = keccak256(
            "SettlementIntent(address owner,address sellToken,uint256 sellAmount,address buyToken,uint256 minBuyAmount,address counterparty,uint256 nonce,uint256 deadline,uint256 policyNonce,uint256 feeBps,address feeRecipient)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                iA.owner,
                iA.sellToken,
                iA.sellAmount,
                iA.buyToken,
                iA.minBuyAmount,
                iA.counterparty,
                iA.nonce,
                iA.deadline,
                iA.policyNonce,
                iA.feeBps,
                iA.feeRecipient
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("BilateralSettlement"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );

        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        assertEq(settlement.intentDigest(iA), expected);
    }

    function test_settle_feeOnTransfer_withSlippage_succeeds() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("FeeA", "FA", 18, 100); // 1% fee
        feeToken.mint(ownerA, 10_000e18);
        vm.prank(ownerA);
        feeToken.approve(address(settlement), type(uint256).max);

        // Update policies; policyNonce increments to 2 for both
        _setPolicy(ownerA, agentA, address(feeToken), address(tokenB), 0);
        _setPolicy(ownerB, agentB, address(tokenB), address(feeToken), 0);

        SettlementIntent memory iA = SettlementIntent({
            owner: ownerA,
            sellToken: address(feeToken),
            sellAmount: 100e18,
            buyToken: address(tokenB),
            minBuyAmount: 200e18, // gets exactly 200e18 tokenB (no fee)
            counterparty: ownerB,
            nonce: settlement.nonces(ownerA),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerA),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });
        SettlementIntent memory iB = SettlementIntent({
            owner: ownerB,
            sellToken: address(tokenB),
            sellAmount: 200e18,
            buyToken: address(feeToken),
            minBuyAmount: 98e18, // 2% tolerance: gets 99e18 ≥ 98e18
            counterparty: ownerA,
            nonce: settlement.nonces(ownerB),
            deadline: block.timestamp + 1 hours,
            policyNonce: registry.policyNonce(ownerB),
            feeBps: settlement.feeBps(),
            feeRecipient: settlement.feeRecipient()
        });

        settlement.settle(iA, _sign(iA, agentAKey), iB, _sign(iB, agentBKey));

        assertEq(tokenB.balanceOf(ownerA), 200e18);
        assertEq(feeToken.balanceOf(ownerB), 99e18); // 100e18 - 1% fee
    }
}
