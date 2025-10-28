// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title IBirdieswapRouterV1
 * @author Birdieswap Team
 * @notice External interface for Birdieswap Router V1.
 * @dev    Intended for integrators/wrappers/off-chain systems. Purely declarative.
 */
interface IBirdieswapRouterV1 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    // ───────────────────── User interactions ─────────────────────
    /**
     * @notice Emitted after a swap of underlying-in → underlying-out is completed.
     * @dev    `user` uses tx.origin intentionally to reflect the end user even when a wrapper/relayer calls the router.
     *         `caller` uses msg.sender to keep richer context. `referrerAddress` is for analytics/attribution only.
     *         This event is not used for access control.
     */
    event Swap(
        address indexed user,
        address indexed caller,
        address tokenIn,
        uint24 feeTier,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed referrerAddress
    );

    // ──────────────────── Governance / Admin ─────────────────────
    event GlobalPaused(address account); // Global paused by governance.
    event GlobalUnpaused(address account); // Global pause is now unpaused by governance.
    event DepositsPaused(address account); // Deposits (and swaps, which require deposits) were paused by governance.
    event DepositsUnpaused(address account); // Deposits (and swaps) were unpaused by governance.
    event SwapsPaused(address account); // Swaps were paused by governance.
    event SwapsUnpaused(address account); // Swaps were unpaused by governance.
    event SingleVaultMappingSet(address indexed underlyingTokenAddress, address indexed bTokenAddressOld, address indexed bTokenAddressNew); // Underlying ↔ Single vault mapping set/confirmed.
    event DualVaultMappingSet(
        address indexed bToken0Address,
        address indexed bToken1Address,
        address blpTokenAddressOld,
        address indexed blpTokenAddressNew
    ); // Ordered (bToken0<bToken1) ↔ Dual vault mapping set/confirmed.
    event RouterUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader); // Emitted when the router implementation is upgraded.

    /*//////////////////////////////////////////////////////////////
                                PAUSING
    //////////////////////////////////////////////////////////////*/

    /// @notice Trigger global pause (blocks all state-changing functions).
    function pause() external;

    /// @notice Lift global pause.
    function unpause() external;

    /// @notice Pause all deposit-like flows (and swaps which depend on deposits).
    function pauseDeposits() external;

    /// @notice Lift the deposit pause.
    function unpauseDeposits() external;

    /// @notice Returns true if deposits (and swaps) are paused.
    function depositsPaused() external view returns (bool);

    /// @notice Pause all swap-related functions (for external DEX emergency).
    function pauseSwaps() external;

    /// @notice Lift the swap pause.
    function unpauseSwaps() external;

    /// @notice Returns true if swaps are paused.
    function swapsPaused() external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                                 VIEW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Return total assets held by a SingleVault.
     * @param _vault Address of the SingleVault (bToken).
     * @return Total asset amount as defined by the SingleVault.
     */
    function totalAssets(address _vault) external view returns (uint256);

    /**
     * @notice Return total assets held by a DualVault.
     * @param _vault Address of the DualVault (BLP).
     * @return Total liquidity under management by the DualVault.
     */
    function totalDualAssets(address _vault) external view returns (uint256);

    /**
     * @notice Return total supply of a SingleVault’s bToken.
     * @param _vault Address of the SingleVault (bToken).
     * @return Total supply of the bToken.
     */
    function totalSupply(address _vault) external view returns (uint256);

    /**
     * @notice Return total supply of a DualVault’s LP token (BLP).
     * @param _vault Address of the DualVault (BLP).
     * @return Total supply of the BLP.
     */
    function totalDualSupply(address _vault) external view returns (uint256);

    /**
     * @notice Return the amount of vanilla underlying tokens held by a SingleVault.
     * @param _vault Address of the SingleVault (bToken).
     * @return Amount of vanilla underlying tokens.
     */
    function totalUnderlyingTokens(address _vault) external view returns (uint256);

    /**
     * @notice Return the vanilla underlying balances managed by a DualVault.
     * @param _vault Address of the DualVault (BLP).
     * @return underlyingToken0 Address of token0 (vanilla underlying).
     * @return underlyingToken1 Address of token1 (vanilla underlying).
     * @return underlyingAmount0 Amount of token0 held.
     * @return underlyingAmount1 Amount of token1 held.
     */
    function totalDualUnderlyingTokens(
        address _vault
    ) external view returns (address underlyingToken0, address underlyingToken1, uint256 underlyingAmount0, uint256 underlyingAmount1);

    /**
     * @notice Preview bTokens minted for depositing a vanilla underlying amount into a SingleVault.
     * @param _vault SingleVault (bToken) address.
     * @param _underlyingTokenAmount Vanilla underlying amount.
     * @return bTokenAmount Previewed bTokens minted.
     */
    function previewFullDeposit(address _vault, uint256 _underlyingTokenAmount) external view returns (uint256 bTokenAmount);

    /**
     * @notice Preview vanilla underlying required to mint a given bToken amount.
     * @param _vault SingleVault (bToken) address.
     * @param _bTokenAmount Desired bToken amount.
     * @return underlyingTokenAmount Previewed vanilla underlying required.
     */
    function previewFullMint(address _vault, uint256 _bTokenAmount) external view returns (uint256 underlyingTokenAmount);

    /**
     * @notice Preview vanilla underlying returned by redeeming a given bToken amount.
     * @param _vault SingleVault (bToken) address.
     * @param _bTokenAmount bToken amount to redeem.
     * @return underlyingTokenAmount Previewed vanilla underlying returned.
     */
    function previewFullRedeem(address _vault, uint256 _bTokenAmount) external view returns (uint256 underlyingTokenAmount);

    /**
     * @notice Preview bTokens burned to withdraw a given vanilla underlying amount.
     * @param _vault SingleVault (bToken) address.
     * @param _underlyingTokenAmount Desired vanilla underlying withdrawal amount.
     * @return bTokenAmount Previewed bTokens burned.
     */
    function previewFullWithdraw(address _vault, uint256 _underlyingTokenAmount) external view returns (uint256 bTokenAmount);

    /**
     * @notice Return the ERC4626 `asset()` of a SingleVault (Birdieswap’s proof token).
     * @param _vault SingleVault (bToken) address.
     * @return underlyingToken Proof token as reported by ERC4626 `asset()` (may differ from Birdieswap’s
     * vanilla underlying).
     */
    function asset(address _vault) external view returns (address underlyingToken);

    /**
     * @notice Retrieve the Uniswap v3 fee tier used by a DualVault.
     * @param _vault DualVault address.
     * @return feeTier Uniswap fee tier.
     */
    function getFeeTier(address _vault) external view returns (uint24 feeTier);

    /// @notice Returns the current router implementation address.
    function getImplementation() external view returns (address);

    /**
     * @notice Resolve SingleVault address by vanilla underlying token.
     * @param _underlyingToken Vanilla underlying ERC20.
     * @return bTokenAddress SingleVault (bToken) address.
     */
    function getBTokenAddress(address _underlyingToken) external view returns (address bTokenAddress);

    /**
     * @notice Resolve vanilla underlying token by SingleVault address.
     * @param _bTokenAddress SingleVault (bToken) address.
     * @return underlyingToken Vanilla underlying ERC20 address.
     */
    function getUnderlyingTokenAddress(address _bTokenAddress) external view returns (address underlyingToken);

    /**
     * @notice Return the ordered bToken pair for a DualVault.
     * @param _blpTokenAddress DualVault address.
     * @return bToken0Address Address of token0 (<= token1).
     * @return bToken1Address Address of token1 (>= token0).
     */
    function getBTokenPair(address _blpTokenAddress) external view returns (address bToken0Address, address bToken1Address);

    /**
     * @notice Resolve DualVault address from an unordered bToken pair.
     * @param _bToken0Address bToken A.
     * @param _bToken1Address bToken B.
     * @return blpTokenAddress DualVault address for the ordered pair (min(A,B), max(A,B)).
     */
    function getBLPTokenAddress(address _bToken0Address, address _bToken1Address) external view returns (address blpTokenAddress);

    /// @notice Fetch single vault state: totalAssets(), totalSupply(), totalUnderlyingTokens().
    function getVaultState(address _vaultAddress) external view returns (uint256, uint256, uint256);

    /// @notice Canonical helper to check bToken ordering for the wrapper and other integrators.
    function isBToken0First(address _bToken0Address, address _bToken1Address) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Map a vanilla underlying token to its SingleVault (bToken).
     * @param _underlyingToken Vanilla underlying ERC20.
     * @param _bTokenAddress   SingleVault (bToken) address.
     */
    function setSingleVaultMapping(address _underlyingToken, address _bTokenAddress) external;

    /**
     * @notice Map an ordered bToken pair to a DualVault.
     * @param _bToken0Address Address of token0 (<= token1).
     * @param _bToken1Address Address of token1 (>= token0).
     * @param _blpTokenAddress DualVault address (BLP).
     */
    function setDualVaultMapping(address _bToken0Address, address _bToken1Address, address _blpTokenAddress) external;

    /*//////////////////////////////////////////////////////////////
                             USER OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit vanilla underlying into a SingleVault and router mints bTokens then pushes them to
     * msg.sender (Wrapper in the standard flow)
     * @param _underlyingTokenAddress Vanilla underlying ERC20.
     * @param _underlyingAmount Amount to deposit.
     * @return bTokenAmount Router pushes bTokens msg.sender (Wrapper), then the Wrapper forwards to the user.
     */
    function singleDeposit(address _underlyingTokenAddress, uint256 _underlyingAmount) external returns (uint256 bTokenAmount);

    /**
     * @notice Redeem bTokens from a SingleVault into vanilla underlying.
     * @param _bTokenAddress bToken (SingleVault) address.
     * @param _bTokenAmount bToken amount to redeem.
     * @return underlyingAmount Vanilla underlying returned to user.
     */
    function singleRedeem(address _bTokenAddress, uint256 _bTokenAmount) external returns (uint256 underlyingAmount);

    /**
     * @notice Deposit two vanilla underlying tokens, convert to two bTokens, and supply into a dual vault.
     * @dev    The `_accountForAccounting` parameter is used only within vault accounting logic (e.g. analytics
     * or registry).
     *         All minted BLP tokens and any leftover underlyings are sent to `msg.sender`,
     *         not to `_accountForAccounting`.
     * @param  _accountForAccounting Address recorded for accounting only.
     * @param  _underlyingToken0Address Token0 (vanilla underlying).
     * @param  _underlyingToken0Amount Amount of token0.
     * @param  _underlyingToken1Address Token1 (vanilla underlying).
     * @param  _underlyingToken1Amount Amount of token1.
     * @return liquidityAmount BLP minted to `msg.sender`.
     * @return underlyingToken0Returned Leftover token0 returned (if any, to `msg.sender`).
     * @return underlyingToken1Returned Leftover token1 returned (if any, to `msg.sender`).
     */
    function dualDeposit(
        address _accountForAccounting,
        address _underlyingToken0Address,
        uint256 _underlyingToken0Amount,
        address _underlyingToken1Address,
        uint256 _underlyingToken1Amount
    ) external returns (uint256 liquidityAmount, uint256 underlyingToken0Returned, uint256 underlyingToken1Returned);

    /**
     * @notice Redeem BLP token into its two bTokens, then redeem each bToken into vanilla underlying tokens.
     * @dev    The `_accountForAccounting` parameter is used only within vault accounting logic (e.g.
     * analytics).
     *         All redeemed underlying tokens are sent to `msg.sender`, not to `_accountForAccounting`.
     * @param  _accountForAccounting Address recorded for accounting only.
     * @param  _blpTokenAddress Dual vault (BLP token) address.
     * @param  _blpTokenAmount Amount of BLP token to redeem.
     * @return underlyingToken0Amount Amount of underlying token0 redeemed to `msg.sender`.
     * @return underlyingToken1Amount Amount of underlying token1 redeemed to `msg.sender`.
     */
    function dualRedeem(
        address _accountForAccounting,
        address _blpTokenAddress,
        uint256 _blpTokenAmount
    ) external returns (uint256 underlyingToken0Amount, uint256 underlyingToken1Amount);

    /**
     * @notice Swap vanilla underlying in → vanilla underlying out via external DEX.
     * @dev    Internally: deposit underlying-in to bToken-in → swap bToken-in to bToken-out → redeem to
     * underlying-out.
     * @dev    Uses `tx.origin` in the Swap event for analytics only (not for authorization).
     * @param  _underlyingTokenInAddress  Underlying token in.
     * @param  _feeTier                   Uniswap v3 fee tier.
     * @param  _underlyingTokenOutAddress Underlying token out.
     * @param  _underlyingTokenInAmount   Amount of underlying in.
     * @param  _underlyingTokenOutMinimumAmount Minimum expected underlying out.
     * @param  _sqrtPriceLimitX96         Uniswap price limit parameter.
     * @param  _referrerAddress           Optional referrer address for analytics.
     * @return underlyingTokenOutAmount   Amount of underlying actually received.
     */
    function swap(
        address _underlyingTokenInAddress,
        uint24 _feeTier,
        address _underlyingTokenOutAddress,
        uint256 _underlyingTokenInAmount,
        uint256 _underlyingTokenOutMinimumAmount,
        uint160 _sqrtPriceLimitX96,
        address _referrerAddress
    ) external returns (uint256 underlyingTokenOutAmount);
}
