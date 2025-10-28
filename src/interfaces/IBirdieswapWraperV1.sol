// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title IBirdieswapWrapperV1
 * @notice Interface for Birdieswap's canonical ETH↔WETH wrapper.
 *
 * @dev The wrapper bridges native ETH to ERC20 WETH for interaction with the
 *      BirdieswapRouterV1. It supports single- and dual-asset deposits and redemptions,
 *      as well as ETH-based swaps. The wrapper itself is stateless and immutable.
 *
 * Security assumptions:
 * - The Router (i_router) is governance-controlled and timelocked.
 * - The Router never calls back into this wrapper.
 * - WETH9 is canonical and immutable.
 * - Only standard ERC20 tokens (non-rebasing, non-deflationary) are listed.
 *
 * Implemented by: BirdieswapWrapperV1.sol
 */
interface IBirdieswapWrapperV1 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits native ETH into a single vault.
    event SingleDepositETH(address indexed user, uint256 ethAmount, uint256 bTokenAmount);

    /// @notice Emitted when a user redeems a single vault position back to ETH.
    event SingleRedeemETH(address indexed user, address indexed bToken, uint256 wethAmount);

    /// @notice Emitted when a user deposits ETH and another ERC20 into a dual vault.
    event DualDepositWithETH(address indexed user, uint256 ethAmount, address tokenAddress, uint256 tokenAmount, uint256 blpTokenAmount);

    /// @notice Emitted when a user redeems a dual-vault LP token back into ETH + ERC20.
    event DualRedeemToETH(
        address indexed user,
        address indexed blpToken,
        address token0Address,
        uint256 token0Amount,
        address token1Address,
        uint256 token1Amount
    );

    /// @notice Emitted when a user swaps native ETH for an ERC20 through the router.
    event SwapFromETH(address indexed user, uint256 ethIn, address tokenOut, uint256 amountOut);

    /// @notice Emitted when a user swaps an ERC20 for native ETH.
    event SwapToETH(address indexed user, address tokenIn, uint256 tokenInAmount, uint256 ethOut);

    /*//////////////////////////////////////////////////////////////
                                CORE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the BirdieswapRouterV1 address used by this wrapper.
     */
    function getRouterAddress() external view returns (address);

    /**
     * @notice Returns the canonical WETH9 address used by this wrapper.
     */
    function getWETHAddress() external view returns (address);

    /**
     * @notice Deposits native ETH into a single-asset vault via the router.
     * @dev Wraps ETH → WETH, forwards to router, and transfers minted bTokens to msg.sender.
     * @return minted Amount of bTokens minted by the vault.
     */
    function singleDepositWithETH() external payable returns (uint256 minted);

    /**
     * @notice Redeems a single-asset vault position back to ETH.
     * @param _bTokenAddress Address of the bToken (SingleVault) to redeem.
     * @param _bTokenAmount Amount of bTokens to redeem.
     * @return wethAmount Amount of ETH unwrapped and returned to the user.
     */
    function singleRedeemToETH(address _bTokenAddress, uint256 _bTokenAmount) external returns (uint256 wethAmount);

    /**
     * @notice Deposits ETH and another ERC20 into a dual vault via the router.
     * @param _underlyingTokenAddress Address of the second underlying ERC20 token.
     * @param _underlyingTokenAmount Amount of that ERC20 to deposit.
     * @return blpTokenAmount Amount of BLP (dual vault LP token) minted.
     * @return underlyingToken0AmountReturned ETH-side refund (in underlying units).
     * @return underlyingToken1AmountReturned ERC20-side refund (in underlying units).
     */
    function dualDepositWithETH(
        address _underlyingTokenAddress,
        uint256 _underlyingTokenAmount
    ) external payable returns (uint256 blpTokenAmount, uint256 underlyingToken0AmountReturned, uint256 underlyingToken1AmountReturned);

    /**
     * @notice Redeems a dual-vault LP token (BLP) back to ETH + ERC20.
     * @param _blpTokenAddress Address of the BLP token to redeem.
     * @param _blpTokenAmount Amount of BLP tokens to redeem.
     * @return token0Amount Amount of token0 returned (ETH side if applicable).
     * @return token1Amount Amount of token1 returned (ERC20 side if applicable).
     */
    function dualRedeemToETH(
        address _blpTokenAddress,
        uint256 _blpTokenAmount
    ) external returns (uint256 token0Amount, uint256 token1Amount);

    /**
     * @notice Swaps native ETH for a target ERC20 token through the router.
     * @param _feeTier Uniswap V3 fee tier for the pool.
     * @param _tokenOut Token to receive.
     * @param _minAmountOut Minimum acceptable output in tokenOut.
     * @param _sqrtPriceLimitX96 Uniswap V3 price limit (X96 encoded).
     * @param _referrerAddress Optional referral or affiliate address.
     * @return amountOut Amount of tokenOut received.
     */
    function swapFromETH(
        uint24 _feeTier,
        address _tokenOut,
        uint256 _minAmountOut,
        uint160 _sqrtPriceLimitX96,
        address _referrerAddress
    ) external payable returns (uint256 amountOut);

    /**
     * @notice Swaps an ERC20 for native ETH through the router.
     * @param _tokenIn Token to spend.
     * @param _feeTier Uniswap V3 fee tier for the pool.
     * @param _amountIn Amount of tokenIn to swap.
     * @param _minAmountOut Minimum acceptable output in WETH terms.
     * @param _sqrtPriceLimitX96 Uniswap V3 price limit (X96 encoded).
     * @param _referrerAddress Optional referral or affiliate address.
     * @return wethAmount Amount of ETH received.
     */
    function swapToETH(
        address _tokenIn,
        uint24 _feeTier,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint160 _sqrtPriceLimitX96,
        address _referrerAddress
    ) external returns (uint256 wethAmount);
}
