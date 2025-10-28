// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            INTERFACE
//////////////////////////////////////////////////////////////*/
/**
 * @title  IBirdieswapRoleRouterV1
 * @author Birdieswap
 * @notice Interface for BirdieswapRoleRouterV1 — the centralized authority
 *         that manages and verifies access roles across all protocol modules.
 * @dev    Modules should rely on this interface to query or batch-update roles,
 *         rather than implementing individual AccessControl logic.
 */
interface IBirdieswapRoleRouterV1 {
    /*//////////////////////////////////////////////////////////////
                                VIEW
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Checks whether an account holds a specific role globally.
     * @param  role     Role hash constant (e.g. CONFIG.MANAGER_ROLE()).
     * @param  account  Address to verify.
     * @return bool     True if the account has the specified role.
     */
    function hasRoleGlobal(bytes32 role, address account) external view returns (bool);

    /**
     * @notice Returns the address of the Config contract that defines the role constants.
     */
    function i_config() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Grants a role to multiple accounts in a single transaction.
     * @dev    Caller must be the admin of the role.
     * @param  role      Role hash constant.
     * @param  accounts  Array of addresses to grant the role to.
     */
    function grantRoleBatch(bytes32 role, address[] calldata accounts) external;

    /**
     * @notice Revokes a role from multiple accounts in a single transaction.
     * @dev    Caller must be the admin of the role.
     * @param  role      Role hash constant.
     * @param  accounts  Array of addresses to revoke the role from.
     */
    function revokeRoleBatch(bytes32 role, address[] calldata accounts) external;
}
