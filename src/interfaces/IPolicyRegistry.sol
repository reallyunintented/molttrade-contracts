// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

import "../types/MoltTradeTypes.sol";

interface IPolicyRegistry {
    event PolicySet(address indexed owner, address indexed agent, uint64 validUntil);
    event PolicyRevoked(address indexed owner);
    event PolicyPaused(address indexed owner);
    event PolicyUnpaused(address indexed owner);

    function setPolicy(PolicyConfig calldata config, PolicyAddresses calldata addrs) external;
    function revokePolicy() external;
    function pausePolicy() external;
    function unpausePolicy() external;

    function activeAgent(address owner) external view returns (address);
    function policyValid(address owner) external view returns (bool);
    function policyNonce(address owner) external view returns (uint256);
    function checkTrade(
        address owner,
        address sellToken,
        address buyToken,
        uint256 amount,
        address counterparty
    ) external view returns (bool);
}
