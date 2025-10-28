// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title  BirdieswapRoleSignaturesV1
 * @notice Central registry for all protocol-wide role identifiers.
 * @dev    Import this contract wherever role constants are required.
 *         Ensures consistent and collision-proof role signatures across modules.
 */
abstract contract BirdieswapRoleSignaturesV1 {
    // ────────────────────── Role Signatures ──────────────────────
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_FULL_ROLE = keccak256("GUARDIAN_FULL_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
}
