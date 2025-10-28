// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title  IBirdieswapDualStrategyV1
 * @author Birdieswap
 * @notice Interface for Birdieswap Dual Strategy V1 (Uniswap V3 style).
 * @dev    Defines the external functions exposed to the Birdieswap DualVault and integrators.
 *         This strategy acts as the execution layer bridging the Birdieswap DualVault and
 *         Uniswap V3, managing liquidity, harvesting, compounding, and emergency exits.
 *
 *         ─────────────────────────────────────────────────────────────
 *         OVERVIEW
 *         ─────────────────────────────────────────────────────────────
 *         • Each DualVault owns a Uniswap V3 position NFT.
 *         • This strategy operates the position (via approved NFT) to:
 *           - Add/remove liquidity
 *           - Harvest and compound fees
 *           - Handle emergency exits
 *         • All state-changing functions are restricted to `onlyDualVault`.
 *         • Read-only view functions provide on-chain state visibility.
 */
interface IBirdieswapDualStrategyV1 {
    /*//////////////////////////////////////////////////////////////
                                CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds liquidity to the Uniswap V3 position using bTokens pulled from the DualVault.
     * @dev    TWAP ratio validation guards against price manipulation; spot/TWAP deviation must be
     *         within `i_maxSlippageRateLiquidity`. Any unused bTokens are returned to the DualVault.
     *         Callable only by the DualVault.
     * @param  _bToken0Amount Amount of bToken0 supplied by the DualVault.
     * @param  _bToken1Amount Amount of bToken1 supplied by the DualVault.
     * @return liquidity      Liquidity added to the Uniswap position.
     * @return unused0        Unused bToken0 amount returned to the DualVault.
     * @return unused1        Unused bToken1 amount returned to the DualVault.
     */
    function deposit(uint256 _bToken0Amount, uint256 _bToken1Amount)
        external
        returns (uint256 liquidity, uint256 unused0, uint256 unused1);

    /**
     * @notice Redeems liquidity back into bTokens for the DualVault.
     * @dev    TWAP safety check ensures current price is close to TWAP. Min amounts are derived from TWAP.
     *         Callable only by the DualVault.
     * @param  _blpTokenAmount Liquidity (Uniswap units) to redeem.
     * @return bToken0Amount   Amount of bToken0 returned to the DualVault.
     * @return bToken1Amount   Amount of bToken1 returned to the DualVault.
     */
    function redeem(uint256 _blpTokenAmount) external returns (uint256 bToken0Amount, uint256 bToken1Amount);

    /**
     * @notice Harvests fees, pays the fixed WETH processing fee, rebalances, and compounds.
     * @dev    Keeper-triggered. TWAP guards apply to swaps. Callable only by the DualVault.
     * @return liquidity New Uniswap liquidity added post-compounding.
     */
    function doHardWork() external returns (uint256 liquidity);

    /**
     * @notice Emergency procedure: removes all liquidity; NFT remains in the DualVault.
     * @dev    For severe incidents only. Collects fees, returns all balances to the DualVault,
     *         and emits `EmergencyExit`. Callable only by the DualVault.
     * @return amount0 Amount of bToken0 returned.
     * @return amount1 Amount of bToken1 returned.
     */
    function emergencyExit() external returns (uint256 amount0, uint256 amount1);

    /*//////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the contract version string.
     */
    function getVersion() external pure returns (string memory);

    /**
     * @notice Returns the Uniswap V3 position tokenId managed by this strategy.
     */
    function getTokenId() external view returns (uint256);

    /**
     * @notice Returns the Uniswap V3 NonfungiblePositionManager address.
     */
    function getPositionManagerAddress() external view returns (address);

    /**
     * @notice Returns the associated Birdieswap DualVault address.
     */
    function getDualVaultAddress() external view returns (address);

    /**
     * @notice Returns the underlying Uniswap V3 pool address.
     */
    function getPoolAddress() external view returns (address);

    /**
     * @notice Returns the Uniswap V3 fee tier (e.g., 500, 3000, 10000) of the managed position.
     * @dev    Used for swap routing and pool identification (not a protocol fee).
     */
    function getFeeTier() external view returns (uint24);

    /**
     * @notice Returns the current Uniswap V3 liquidity (uint128) of the position as uint256.
     * @dev    Reported as uint256 for ERC4626-style accounting compatibility.
     */
    function getPositionLiquidity() external view returns (uint256);

    /**
     * @notice Returns the instantaneous (spot) bToken composition of the position.
     * @dev    Uses pool `slot0` (non-TWAP). Intended for visibility/accounting only.
     * @return token0Addr  Address of bToken0.
     * @return token1Addr  Address of bToken1.
     * @return amount0     Spot-implied amount of bToken0.
     * @return amount1     Spot-implied amount of bToken1.
     */
    function getPositionComposition() external view returns (address token0Addr, address token1Addr, uint256 amount0, uint256 amount1);

    /*//////////////////////////////////////////////////////////////
                                ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC721 receiver hook — strategy must never take NFT custody; always reverts in implementation.
     * @dev    Included for interface completeness.
     * @param  operator Address initiating the transfer.
     * @param  from     Previous NFT owner.
     * @param  tokenId  ID of the received NFT.
     * @param  data     Additional calldata (unused).
     * @return selector ERC721Receiver selector confirmation.
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4 selector);
}
