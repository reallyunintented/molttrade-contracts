// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "./interfaces/IBilateralSettlement.sol";
import "./interfaces/IPolicyRegistry.sol";
import "./libraries/SafeToken.sol";
import "./types/MoltTradeTypes.sol";

contract BilateralSettlement is IBilateralSettlement {
    uint256 public constant MAX_FEE_BPS = 100;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECP256K1N_HALVED =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("BilateralSettlement");
    bytes32 private constant VERSION_HASH = keccak256("1");

    IPolicyRegistry public immutable registry;

    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;

    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "SettlementIntent(address owner,address sellToken,uint256 sellAmount,address buyToken,uint256 minBuyAmount,address counterparty,uint256 nonce,uint256 deadline,uint256 policyNonce,uint256 feeBps,address feeRecipient)"
    );

    mapping(address => uint256) public nonces;

    address public owner;
    address public feeRecipient;
    uint256 public feeBps;
    address public pendingOwner;
    bool public paused;

    bool private _entered;

    error Reentrancy();
    error NotOwner();
    error NotPendingOwner();
    error Paused();
    error AlreadyPaused();
    error NotPaused();
    error Expired();
    error BadNonce();
    error BadSignature();
    error IncompatibleIntents();
    error AmountNotMet();
    error PolicyCheckFailed(address owner);
    error InvalidFeeConfig();

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address registry_) {
        registry = IPolicyRegistry(registry_);
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function setFee(uint256 bps, address recipient) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert InvalidFeeConfig();
        if (bps > 0 && recipient == address(0)) revert InvalidFeeConfig();

        feeBps = bps;
        feeRecipient = recipient;

        emit FeeUpdated(bps, recipient);
    }

    /// @notice Burn the caller's next intent nonce. The owner — not the agent —
    /// invalidates one pending signed intent without touching policy state, so
    /// other in-flight intents from the same agent remain valid.
    function cancelNonce() external {
        uint256 cancelled = nonces[msg.sender]++;
        emit NonceCancelled(msg.sender, cancelled);
    }

    /// @notice Pause new settlements. Only callable by owner.
    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Resume new settlements after a pause. Only callable by owner.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Begin a two-step ownership transfer. Sets `pendingOwner`; the
    /// transfer does not take effect until `acceptOwnership` is called by the
    /// pending owner. Pass `address(0)` to cancel a pending transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            emit OwnershipTransferCanceled(owner, pendingOwner);
        } else {
            emit OwnershipTransferStarted(owner, newOwner);
        }
        pendingOwner = newOwner;
    }

    /// @notice Complete a two-step ownership transfer. Callable only by the
    /// current `pendingOwner`. Clears `pendingOwner` on success.
    function acceptOwnership() external {
        address pending = pendingOwner;
        // `msg.sender != pending` already rejects pending == address(0),
        // since msg.sender cannot be address(0) in any EVM transaction.
        if (msg.sender != pending) revert NotPendingOwner();

        address previousOwner = owner;
        owner = pending;
        pendingOwner = address(0);

        emit OwnershipTransferred(previousOwner, pending);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)
            )
        );
    }

    function _domainSeparator() private view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _cachedDomainSeparator;
        return _buildDomainSeparator();
    }

    function intentDigest(SettlementIntent calldata intent) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        INTENT_TYPEHASH,
                        intent.owner,
                        intent.sellToken,
                        intent.sellAmount,
                        intent.buyToken,
                        intent.minBuyAmount,
                        intent.counterparty,
                        intent.nonce,
                        intent.deadline,
                        intent.policyNonce,
                        intent.feeBps,
                        intent.feeRecipient
                    )
                )
            )
        );
    }

    function settle(
        SettlementIntent calldata intentA,
        bytes calldata sigA,
        SettlementIntent calldata intentB,
        bytes calldata sigB
    ) external whenNotPaused nonReentrant {
        // 0. Owners must be distinct
        if (intentA.owner == intentB.owner) revert IncompatibleIntents();

        // 1. Deadlines
        if (block.timestamp > intentA.deadline) revert Expired();
        if (block.timestamp > intentB.deadline) revert Expired();

        // 2. Nonces — check then increment. Safe: EVM reverts all state changes if
        //    any later check fails, so premature increment cannot strand an owner's nonce.
        if (intentA.nonce != nonces[intentA.owner]) revert BadNonce();
        if (intentB.nonce != nonces[intentB.owner]) revert BadNonce();
        nonces[intentA.owner]++;
        nonces[intentB.owner]++;

        // 3. Signature verification — signer must be active agent per registry
        address agentA = registry.activeAgent(intentA.owner);
        address agentB = registry.activeAgent(intentB.owner);
        if (agentA == address(0)) revert PolicyCheckFailed(intentA.owner);
        if (agentB == address(0)) revert PolicyCheckFailed(intentB.owner);
        // agentA/agentB != address(0) guaranteed above; ecrecover returning address(0) cannot bypass these checks
        if (_recover(intentDigest(intentA), sigA) != agentA) revert BadSignature();
        if (_recover(intentDigest(intentB), sigB) != agentB) revert BadSignature();

        // 4. Token compatibility: tokens must differ; A sells what B buys and vice versa
        if (intentA.sellToken == intentB.sellToken) revert IncompatibleIntents();
        if (intentA.sellToken != intentB.buyToken) revert IncompatibleIntents();
        if (intentB.sellToken != intentA.buyToken) revert IncompatibleIntents();

        // 5. Fee config must match across intents and the current onchain setting
        if (intentA.feeBps != intentB.feeBps) revert InvalidFeeConfig();
        if (intentA.feeRecipient != intentB.feeRecipient) revert InvalidFeeConfig();
        if (intentA.feeBps != feeBps) revert InvalidFeeConfig();
        if (intentA.feeRecipient != feeRecipient) revert InvalidFeeConfig();
        if (intentA.feeBps > MAX_FEE_BPS) revert InvalidFeeConfig();
        if (intentA.feeBps > 0 && intentA.feeRecipient == address(0)) revert InvalidFeeConfig();

        uint256 feeAmountA = _feeAmount(intentA.sellAmount, intentA.feeBps);
        uint256 feeAmountB = _feeAmount(intentB.sellAmount, intentB.feeBps);
        uint256 netAmountA = intentA.sellAmount - feeAmountA;
        uint256 netAmountB = intentB.sellAmount - feeAmountB;

        // 6. Amount pre-check (declared gross amounts minus protocol fee)
        if (netAmountB < intentA.minBuyAmount) revert AmountNotMet();
        if (netAmountA < intentB.minBuyAmount) revert AmountNotMet();

        // 7. Explicit counterparty required — open-fill (address(0)) not permitted
        if (intentA.counterparty == address(0) || intentB.counterparty == address(0)) {
            revert IncompatibleIntents();
        }
        if (intentA.counterparty != intentB.owner) revert IncompatibleIntents();
        if (intentB.counterparty != intentA.owner) revert IncompatibleIntents();

        // 8. Policy nonce — stale intent guard
        if (intentA.policyNonce != registry.policyNonce(intentA.owner)) revert BadNonce();
        if (intentB.policyNonce != registry.policyNonce(intentB.owner)) revert BadNonce();

        // 9. Policy checks via registry
        _checkPolicy(intentA, intentB.owner);
        _checkPolicy(intentB, intentA.owner);

        // 10. Snapshot recipient balances before transfers
        // intentA.buyToken == intentB.sellToken (enforced step 4)
        // intentB.buyToken == intentA.sellToken (enforced step 4)
        uint256 preOwnerABuy = SafeToken.balanceOf(intentA.buyToken, intentA.owner);
        uint256 preOwnerBBuy = SafeToken.balanceOf(intentB.buyToken, intentB.owner);

        // 11. Atomic transfers: skim protocol fee, then cross the net amounts between owners
        _transferSellSide(intentA, intentB.owner, feeAmountA, netAmountA);
        _transferSellSide(intentB, intentA.owner, feeAmountB, netAmountB);

        // 12. Verify actual balance deltas meet minimums (catches fee-on-transfer tokens)
        _assertMinReceived(intentA, preOwnerABuy);
        _assertMinReceived(intentB, preOwnerBBuy);

        _emitSettled(intentA, intentB, feeAmountA, feeAmountB);
    }

    function _feeAmount(uint256 amount, uint256 bps) private pure returns (uint256) {
        return (amount * bps) / BPS_DENOMINATOR;
    }

    function _checkPolicy(SettlementIntent calldata intent, address counterpartyOwner)
        private
        view
    {
        if (!registry.checkTrade(
                intent.owner,
                intent.sellToken,
                intent.buyToken,
                intent.sellAmount,
                counterpartyOwner
            )) {
            revert PolicyCheckFailed(intent.owner);
        }
    }

    function _transferSellSide(
        SettlementIntent calldata intent,
        address counterpartyOwner,
        uint256 feeAmount,
        uint256 netAmount
    ) private {
        if (feeAmount > 0) {
            SafeToken.safeTransferFrom(
                intent.sellToken, intent.owner, intent.feeRecipient, feeAmount
            );
        }
        if (netAmount > 0) {
            SafeToken.safeTransferFrom(intent.sellToken, intent.owner, counterpartyOwner, netAmount);
        }
    }

    function _emitSettled(
        SettlementIntent calldata intentA,
        SettlementIntent calldata intentB,
        uint256 feeAmountA,
        uint256 feeAmountB
    ) private {
        emit Settled(
            intentA.owner,
            intentB.owner,
            intentA.sellToken,
            intentB.sellToken,
            intentA.sellAmount,
            intentB.sellAmount,
            feeAmountA,
            feeAmountB,
            intentA.feeRecipient,
            intentA.feeBps
        );
    }

    function _assertMinReceived(SettlementIntent calldata intent, uint256 preBalance) private view {
        uint256 postBalance = SafeToken.balanceOf(intent.buyToken, intent.owner);
        // Rebasing-down or balance-mutating buy tokens can leave postBalance
        // below preBalance. Treat that as `AmountNotMet` rather than letting
        // a checked subtraction revert with an opaque arithmetic panic.
        if (postBalance < preBalance) revert AmountNotMet();
        unchecked {
            if (postBalance - preBalance < intent.minBuyAmount) revert AmountNotMet();
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > SECP256K1N_HALVED) revert BadSignature();
        if (v != 27 && v != 28) revert BadSignature();

        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert BadSignature();
        return recovered;
    }
}
