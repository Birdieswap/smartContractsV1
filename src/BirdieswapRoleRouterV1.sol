// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { AccessControl } from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapRoleRouterV1
 * @author Birdieswap
 * @notice Central authority hub that defines and verifies access roles across all protocol modules (Router, Vaults, Staking, etc.).
 * @dev    - Non-upgradeable and immutable by design.
 *         - Built atop OpenZeppelin AccessControl for simplicity and auditability.
 *         - Future revisions should deploy RoleRouterV2 and update each module’s stored router address.
 */
contract BirdieswapRoleRouterV1 is AccessControl {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an expected non-zero address is zero.
    error BirdieswapRoleRouterV1__ZeroAddressNotAllowed();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapRoleRouterV1";

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @param timelockGovernance_  DEFAULT_ADMIN_ROLE is assigned to OpenZepppelin TimelockController (Governance)
     */
    constructor(address timelockGovernance_) {
        if (timelockGovernance_ == address(0)) revert BirdieswapRoleRouterV1__ZeroAddressNotAllowed();

        // Grant the default admin role using Openzeppelin's AccessControl predefined hash(DEFAULT_ADMIN_ROLE).
        _grantRole(DEFAULT_ADMIN_ROLE, timelockGovernance_);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the contract version.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /**
     * @notice Checks if a given account holds a specific role globally.
     * @dev    Modules normally call: `roleRouter.hasRoleGlobal(MANAGER_ROLE(), msg.sender)`.
     * @param  _role     Role hash (keccak256) retrieved from BirdieswapRoleSignaturesV1.
     * @param  _account  Address being queried.
     */
    function hasRoleGlobal(bytes32 _role, address _account) external view returns (bool) {
        return hasRole(_role, _account);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN UTILITIES
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Grants a role to multiple accounts in a single transaction.
     * @dev    Caller must be the admin of that role.
     * @param  _role      Role hash to grant.
     * @param  _accounts  Array of addresses to receive the role.
     */
    function grantRoleBatch(bytes32 _role, address[] calldata _accounts) external onlyRole(getRoleAdmin(_role)) {
        if (_accounts.length == 0) return;
        uint256 length = _accounts.length;
        for (uint256 i; i < length;) {
            address account = _accounts[i];
            if (account != address(0)) _grantRole(_role, account);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Revokes a role from multiple accounts in a single transaction.
     * @dev    Caller must be the admin of that role.
     * @param  _role      Role hash to revoke.
     * @param  _accounts  Array of addresses to lose the role.
     */
    function revokeRoleBatch(bytes32 _role, address[] calldata _accounts) external onlyRole(getRoleAdmin(_role)) {
        if (_accounts.length == 0) return;
        uint256 length = _accounts.length;
        for (uint256 i; i < length;) {
            address account = _accounts[i];
            if (account != address(0)) _revokeRole(_role, account);
            unchecked {
                ++i;
            }
        }
    }
}

/*//////////////////////////////////////////////////////////////
                        END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant Only DEFAULT_ADMIN_ROLE holders may grant or revoke other administrative privileges.
/// @custom:invariant Instead of upgrading this contract, governance should deploy a new RoleRouter version and update each module’s stored
///                   role router address accordingly.
