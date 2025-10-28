// SPDX-License-Identifier: None
pragma solidity 0.8.30;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title LiquidityAmounts (subset)
 * @notice Lightweight local copy of Uniswap V3 liquidity math used for position valuation.
 * @dev    Mirrors v3-periphery implementation but trimmed to only the required function.
 *         SECURITY: Pure math, no external state or calls.
 */
library LiquidityAmounts {
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96

    /**
     * @notice Computes token0/token1 amounts represented by `liquidity` at `sqrtPriceX96`
     *         between [sqrtRatioAX96, sqrtRatioBX96].
     * @dev    Used by BirdieswapDualStrategyV1 for TWAP and spot composition estimation.
     * @param  sqrtPriceX96   Current pool sqrt price (Q64.96).
     * @param  sqrtRatioAX96  Lower bound sqrt price (Q64.96).
     * @param  sqrtRatioBX96  Upper bound sqrt price (Q64.96).
     * @param  liquidity      Position liquidity (uint128 in Uniswap core).
     * @return amount0        Corresponding token0 amount.
     * @return amount1        Corresponding token1 amount.
     */
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Entirely below range: only token0
            amount0 = Math.mulDiv(
                uint256(liquidity) << 96,
                uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96),
                uint256(sqrtRatioAX96) * uint256(sqrtRatioBX96)
            );
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            // Within range: both tokens
            amount0 = Math.mulDiv(
                uint256(liquidity) << 96,
                uint256(sqrtRatioBX96) - uint256(sqrtPriceX96),
                uint256(sqrtPriceX96) * uint256(sqrtRatioBX96)
            );
            amount1 = Math.mulDiv(uint256(liquidity), uint256(sqrtPriceX96) - uint256(sqrtRatioAX96), Q96);
        } else {
            // Entirely above range: only token1
            amount1 = Math.mulDiv(uint256(liquidity), uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96), Q96);
        }
    }
}
