// SPDX-License-Identifier: None
pragma solidity 0.8.30;

import { IBirdieswapDualStrategyV1 } from "./IBirdieswapDualStrategyV1.sol";

/**
 * @title  IBirdieswapDualVaultV1
 * @notice Interface for the Birdieswap Dual Vault V1 (Uniswap V3–style dual-token vault).
 * @dev    This vault manages a dual-token liquidity position represented by an ERC721 NFT (e.g., Uniswap V3
 * position).
 *         Users deposit and redeem pairs of Birdieswap proof tokens (bToken0, bToken1) through this vault,
 *         which interacts with a designated strategy contract implementing {IBirdieswapDualStrategyV1}.
 *
 *         The vault also exposes limited ERC20 (ERC4626 share) functionality so external contracts
 *         and integrations (e.g., routers, frontends) can read balances and perform allowance-based
 * transfers.
 *
 *         Governance is enforced via AccessControl roles:
 *         - {TIMELOCK_ROLE}: TimelockController authorized to update strategies.
 *         - {VAULT_MANAGER_ROLE}: Operations role authorized for doHardWork() and emergencyExit().
 *         - {PAUSER_ROLE}: Guardian able to pause user-facing flows.
 *
 * @custom:security Security principles:
 *         - Strategy replacement is time-locked and verified via `getDualVaultAddress()`.
 *         - ERC721 approval (NFT) ensures only the active strategy can manage liquidity.
 *         - ERC20 SafeERC20 interactions prevent unsafe token transfers.
 *         - NonReentrant and CEI enforced in implementation.
 */
interface IBirdieswapDualVaultV1 {
    /*//////////////////////////////////////////////////////////////
                             GOVERNANCE CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pauses user interactions (deposits/redeems) in emergencies.
     * @dev    Callable only by addresses with {PAUSER_ROLE}.
     */
    function pause() external;

    /**
     * @notice Unpauses the vault after the issue has been mitigated.
     * @dev    Callable only by addresses with {PAUSER_ROLE}.
     */
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total liquidity of the underlying Uniswap V3 position.
     * @dev    Expressed as uint128 (native Uniswap liquidity type).
     * @return liquidity The current liquidity value held by the vault’s position NFT.
     */
    function getLiquidity() external view returns (uint128);

    /**
     * @notice Returns the first proof token (bToken0) address held by the vault.
     */
    function getToken0Address() external view returns (address);

    /**
     * @notice Returns the second proof token (bToken1) address held by the vault.
     */
    function getToken1Address() external view returns (address);

    /**
     * @notice Returns the Birdieswap Router address, if integrated.
     * @dev    May be used by off-chain or router-level integrations.
     */
    function getRouterAddress() external view returns (address);

    /**
     * @notice Returns the currently active strategy managing this vault’s NFT.
     * @return strategyAddress Address of the current strategy.
     */
    function getStrategyAddress() external view returns (address);

    /**
     * @notice Returns the underlying pool address as reported by the strategy.
     * @return poolAddress Address of the Uniswap V3–style pool being managed.
     */
    function getPoolAddress() external view returns (address);

    /**
     * @notice Returns the fee tier (e.g., 500, 3000, 10000) of the current pool.
     * @dev    Retrieved from the underlying strategy’s pool configuration.
     * @return feeTier The fee tier in hundredths of a bip (1e-6 precision).
     */
    function getFeeTier() external view returns (uint24);

    /*//////////////////////////////////////////////////////////////
                             STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Triggers an emergency withdrawal of all assets from the strategy back to the vault.
     * @dev    Callable only by addresses with {VAULT_MANAGER_ROLE}.
     */
    function emergencyExit() external;

    /**
     * @notice Executes the strategy’s periodic compounding or rebalancing routine.
     * @dev    Callable only by addresses with {VAULT_MANAGER_ROLE}.
     * @return newLiquidity The updated liquidity value reported by the strategy.
     */
    function doHardWork() external returns (uint256);

    /**
     * @notice (Legacy) Sets the initial strategy contract during deployment or migration.
     * @param  _initialStrategy Address of the initial strategy contract.
     * @dev    Callable only by governance or timelock.
     */
    function updateInitialStrategy(address _initialStrategy) external;

    /**
     * @notice (Legacy / optional) Proposes a new strategy to be accepted later.
     * @param  _newStrategy Address of the proposed strategy contract.
     * @dev    Typically used by governance-controlled upgraders.
     */
    function proposeStrategy(address _newStrategy) external;

    /**
     * @notice Accepts and activates a previously proposed strategy.
     * @dev    Usually called by the TimelockController after proposal delay.
     */
    function acceptStrategy() external;

    /*//////////////////////////////////////////////////////////////
                             ERC721 HANDLING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC721 receiver hook (required for safe transfers of Uniswap V3 position NFTs).
     * @dev    Must return `IERC721Receiver.onERC721Received.selector` to confirm safe receipt.
     * @param  operator The address that initiated the transfer.
     * @param  from     The address which previously owned the NFT.
     * @param  tokenId  The ERC721 tokenId being transferred.
     * @param  data     Additional call data (if any).
     * @return The ERC721 selector signaling successful receipt.
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);

    /*//////////////////////////////////////////////////////////////
                             USER INTERACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits a dual pair of bTokens into the vault.
     * @param  _userAddress   Address of the user (for event attribution).
     * @param  _bToken0Amount Amount of bToken0 to deposit.
     * @param  _bToken1Amount Amount of bToken1 to deposit.
     * @return mintedShares        Amount of vault shares (blpToken) minted.
     * @return returnToken0Amount  Unused bToken0 returned to user (if any).
     * @return returnToken1Amount  Unused bToken1 returned to user (if any).
     *
     * @dev    This is a Birdieswap-custom dual-token deposit flow, not standard ERC4626.
     *         Both tokens must be nonzero and pre-approved for transfer.
     * @dev    IMPORTANT: paramter order differs from ERC-4626.
     */
    function deposit(address _userAddress, uint256 _bToken0Amount, uint256 _bToken1Amount) external returns (uint256, uint256, uint256);

    /**
     * @notice Redeems vault shares (blpToken) for the underlying pair of bTokens.
     * @param  _caller         The entity initiating the redemption (e.g., router or user).
     * @param  _owner          The owner of the shares to redeem.
     * @param  _blpTokenAmount The amount of shares to burn.
     * @return bToken0Amount   Amount of bToken0 returned to `_owner`.
     * @return bToken1Amount   Amount of bToken1 returned to `_owner`.
     *
     * @dev    Follows the ERC4626-like redemption semantics but dual-token output.
     *         Requires approval if `_caller != _owner`.
     * @dev    IMPORTANT: paramter order differs from ERC-4626.
     */
    function redeem(address _caller, address _owner, uint256 _blpTokenAmount) external returns (uint256, uint256);

    /*//////////////////////////////////////////////////////////////
                       ERC20 / ERC4626 COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current blpToken balance of a user.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Transfers blpTokens to another address.
     * @param  to    Recipient address.
     * @param  value Amount of tokens to transfer.
     * @return success True if transfer succeeded.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @notice Returns the remaining allowance for a spender on behalf of an owner.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @notice Approves a spender to use a specific amount of blpTokens.
     * @param  spender Address to approve.
     * @param  value   Allowance amount.
     * @return success True if approval succeeded.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @notice Transfers tokens using allowance mechanics.
     * @param  from  Address to pull tokens from.
     * @param  to    Recipient address.
     * @param  value Amount to transfer.
     * @return success True if transfer succeeded.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
