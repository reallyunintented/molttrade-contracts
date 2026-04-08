// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

import { BilateralSettlement } from "../src/BilateralSettlement.sol";
import { PolicyRegistry } from "../src/PolicyRegistry.sol";

contract DeployBaseMainnet is Script {
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 internal constant MAX_FEE_BPS = 100;
    address internal constant ZERO_ADDRESS = address(0);

    error WrongChain(uint256 expectedChainId, uint256 actualChainId);
    error EmptySettlementOwner();
    error InvalidInitialFeeConfig(uint256 feeBps, address feeRecipient);

    function run() external returns (PolicyRegistry registry, BilateralSettlement settlement) {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) {
            revert WrongChain(BASE_MAINNET_CHAIN_ID, block.chainid);
        }

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address broadcaster = vm.addr(deployerPrivateKey);
        address settlementOwner = vm.envOr("SETTLEMENT_OWNER", broadcaster);
        uint256 initialFeeBps = vm.envOr("INITIAL_FEE_BPS", uint256(0));
        address initialFeeRecipient = vm.envOr("INITIAL_FEE_RECIPIENT", ZERO_ADDRESS);

        if (settlementOwner == ZERO_ADDRESS) revert EmptySettlementOwner();
        if (initialFeeBps > MAX_FEE_BPS) {
            revert InvalidInitialFeeConfig(initialFeeBps, initialFeeRecipient);
        }
        if (initialFeeBps > 0 && initialFeeRecipient == ZERO_ADDRESS) {
            revert InvalidInitialFeeConfig(initialFeeBps, initialFeeRecipient);
        }

        vm.startBroadcast(deployerPrivateKey);

        registry = new PolicyRegistry();
        settlement = new BilateralSettlement(address(registry));

        if (initialFeeBps > 0) {
            settlement.setFee(initialFeeBps, initialFeeRecipient);
        }

        if (settlementOwner != broadcaster) {
            settlement.transferOwnership(settlementOwner);
        }

        vm.stopBroadcast();

        console2.log("MoltTrade Base mainnet deployment complete");
        console2.log("CHAIN_ID", block.chainid);
        console2.log("DEPLOYER", broadcaster);
        console2.log("POLICY_REGISTRY", address(registry));
        console2.log("SETTLEMENT_CONTRACT", address(settlement));
        console2.log("SETTLEMENT_OWNER", settlementOwner);
        console2.log("INITIAL_FEE_BPS", initialFeeBps);
        console2.log("INITIAL_FEE_RECIPIENT", initialFeeRecipient);
    }
}
