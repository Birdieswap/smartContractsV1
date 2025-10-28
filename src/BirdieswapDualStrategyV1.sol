// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC721Receiver } from "../lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V3 interface imports (v3-periphery v1.4.4, v3-core v1.0.1)
import { INonfungiblePositionManager } from "../lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Pool } from "../lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "../lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

// Derived from Uniswap V3 core/periphery math; reduced and aligned with Birdieswap’s current compiler and coding style.
import { LiquidityAmounts } from "./lib/LiquidityAmounts.sol";
import { TickMath } from "./lib/TickMath.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "./BirdieswapConfigV1.sol";
import { BirdieswapSingleVaultV1 } from "./BirdieswapSingleVaultV1.sol"; // Uses concrete class intentionally.
import { IBirdieswapDualVaultV1 } from "./interfaces/IBirdieswapDualVaultV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapRouterV1 } from "./interfaces/IBirdieswapRouterV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  Birdieswap Dual Strategy V1 (Uniswap V3 style)
 * @author Birdieswap
 * @notice Bridges a Birdieswap DualVault (sole custodian of the Uniswap V3 position NFT) and Uniswap V3. Adds/removes liquidity, harvests &
 *         compounds fees, and shuttles bTokens (Birdieswap SingleVault ERC4626 shares) between the vault and the Uniswap position.
 *
 * @dev ─────────────────────────────────────────────────────────────────────────
 *      ARCHITECTURE
 *      ─────────────────────────────────────────────────────────────────────────
 *      • Custody & approvals
 *        - The Uniswap V3 position NFT is always owned by the DualVault. This Strategy never takes NFT custody; it only operates via the
 *          DualVault’s approval for `tokenId`.
 *        - During initial setup, admin tooling may temporarily hold the NFT to seed configuration, after which it is transferred to the
 *          DualVault and approvals are finalized.
 *
 *      • Internal Birdieswap boundary (trusted)
 *        - Router, SingleVault (bToken), DualVault (blpToken), SingleStrategy, DualStrategy, Wrapper, Staking. These are
 *          protocol-controlled contracts. The Strategy may `forceApprove()` them with max allowance.
 *
 *      • External dependency
 *        - Uniswap V3 (Pool, PositionManager). Treated as untrusted w.r.t. short-term price manipulation. The Strategy uses the built-in
 *          TWAP oracle as a safety check (not as a valuation oracle).
 *
 *      • Asset model
 *        - Liquidity is provided using bTokens (SingleVault shares). Uniswap treats bTokens as arbitrary ERC20s, consistent with
 *          Birdieswap’s proof-token design (no unwrap needed for LP ops).
 *
 *      • Pricing safeguards
 *        - Liquidity ops compare spot vs TWAP with max-slippage constraints.
 *        - Swaps compute conservative `minOut` from TWAP and enforce spot/TWAP deviation bounds.
 *
 *      • Operations
 *        - `doHardWork()` harvests fees, charges a fixed WETH processing fee to the ops multisig, rebalances via the Router, redeposits
 *          into SingleVaults, and increases liquidity again.
 *
 *      • Emergency behavior
 *        - `emergencyExit()` removes all liquidity and transfers resulting bTokens back to the DualVault. The NFT always remains in the
 *          DualVault. Normal operations resume after redeployment.
 *
 *      TRUST MODEL
 *      ─────────────────────────────────────────────────────────────────────────
 *      - Router and all Vaults are Birdieswap-controlled and trusted.
 *      - Router proxy address is stable across upgrades; allowances point to the proxy, not implementation.
 *      - SingleVault bTokens are ERC4626-compliant and contain no external hooks or user-supplied logic.
 *
 *      SECURITY NOTES
 *      ─────────────────────────────────────────────────────────────────────────
 *      - All external methods are gated by `onlyDualVault` and are `nonReentrant`.
 *      - SafeERC20 is used for transfers; no ERC777 hooks are relied upon.
 *      - Fee-on-transfer tokens are not supported by protocol policy (see `_redeemToUnderlyingAndSwapToWETH()`).
 *      - TWAP windows are distinct for liquidity ops vs swaps to balance safety and liveness.
 */
contract BirdieswapDualStrategyV1 is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── ACCESS CONTROL ───────────────────────
    /// @notice Caller is not authorized (only the configured DualVault may call).
    error BirdieswapDualStrategyV1__OnlyDualVaultCanCall();

    // ─────────────────── GENERIC / VALIDATION ────────────────────
    /// @notice Zero or invalid deposit amounts provided.
    error BirdieswapDualStrategyV1__InvalidDepositAmount();
    /// @notice The deposit amount exceeds the strategy’s available bToken balance.
    error BirdieswapDualStrategyV1__DepositAmountExceedsBalance();
    /// @notice Zero or invalid liquidity amount for redemption.
    error BirdieswapDualStrategyV1__InvalidLiquidityAmount();
    /// @notice A required address parameter is zero.
    error BirdieswapDualStrategyV1__ZeroAddressNotAllowed();
    /// @notice Insufficient harvested WETH to pay the fixed processing fee safely.
    error BirdieswapDualStrategyV1__InsufficientWETHForProcessingFee();

    // ────────────────── INITIALIZATION / SETUP ───────────────────
    /// @notice Pool tokens do not match the configured bTokens.
    error BirdieswapDualStrategyV1__PoolTokensMismatch();
    /// @notice NFT tokens do not match the Uniswap pool’s tokens.
    error BirdieswapDualStrategyV1__NFTTokensMismatch();
    /// @notice Pool fee tier in NFT does not correspond to the factory pool.
    error BirdieswapDualStrategyV1__PoolAndFeeTierMismatch();
    /// @notice The Uniswap V3 position NFT has not been minted yet.
    error BirdieswapDualStrategyV1__NFTNotMinted();
    /// @notice Router does not have a valid bToken ↔ underlying mapping.
    error BirdieswapDualStrategyV1__RouterMappingMissing();
    /// @notice Invalid configuration parameter detected.
    error BirdieswapDualStrategyV1__InvalidConfiguration();

    // ─────────────────── POOL / POSITION STATE ───────────────────
    /// @notice The Uniswap position NFT is not owned by the DualVault.
    error BirdieswapDualStrategyV1__PositionNotOwnedByDualVault();
    /// @notice No remaining liquidity to withdraw from the position.
    error BirdieswapDualStrategyV1__NoLiquidityLeftToWithdraw();
    /// @notice Liquidity delta after operation does not match expected values.
    error BirdieswapDualStrategyV1__LiquidityInvariantMismatch();
    /// @notice bToken redemption invariant violated (balance mismatch).
    error BirdieswapDualStrategyV1__BTokenRedeemInvariantMismatch();
    /// @notice No underlying token received upon redemption.
    error BirdieswapDualStrategyV1__NoUnderlyingReceivedOnRedeem();

    // ─────────────────── TWAP / PRICING GUARDS ───────────────────
    /// @notice Invalid token pair provided for TWAP calculation.
    error BirdieswapDualStrategyV1__InvalidTokensForTWAP();
    /// @notice Invalid or zero price observed during TWAP calculation.
    error BirdieswapDualStrategyV1__InvalidPriceForTWAP();
    /// @notice Spot/TWAP deviation exceeds allowed slippage bounds.
    error BirdieswapDualStrategyV1__TWAPDeviationExceeded();
    /// @notice Uniswap V3 pool not found for the given tokens and fee tier.
    error BirdieswapDualStrategyV1__PoolNotFound();

    // ───────────────── NUMERIC / INTERNAL SAFETY ─────────────────
    /// @notice Overflow detected when downcasting uint256 → uint128.
    error BirdieswapDualStrategyV1__Uint128Overflow();

    // ──────────────── RECEIVER / INVARIANT SAFETY ────────────────
    /// @notice Strategy must never take custody of the Uniswap V3 NFT directly.
    error BirdieswapDualStrategyV1__NFTTransferNotAccepted();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── Version ──────────────────────────
    /// @notice Contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapDualStrategyV1";

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Event Relayer ───────────────────────
    /// @notice Event relayer contract for emitting global protocol events.
    IBirdieswapEventRelayerV1 private immutable i_event;

    // ─────────────────────────── Tokens ──────────────────────────
    /// @notice Ordered pair of Birdieswap bTokens (SingleVault addresses) used as Uniswap pair.
    address private immutable i_bToken0Address;
    address private immutable i_bToken1Address;

    /// @notice The DualVault (also the ERC20 LP token) that owns the Uniswap position NFT.
    address private immutable i_blpTokenAddress;

    /// @notice WETH token address (used as the common quote asset).
    address private immutable i_wethAddress;

    // ───────────────────────────── DEX ───────────────────────────
    /// @notice Uniswap V3 position tokenId managed (by approval) under DualVault custody.
    uint256 private immutable i_tokenId;

    /// @notice Underlying Uniswap V3 pool address corresponding to the position.
    address private immutable i_poolAddress;

    /// @notice Uniswap V3 NonfungiblePositionManager address for this chain.
    address private immutable i_positionManagerAddress;

    /// @notice Uniswap V3 factory address used for pool validation and lookups.
    address private immutable i_uniswapFactoryAddress;

    /// @notice Deadline delta for Uniswap liquidity operations (increase/decrease).
    uint256 private immutable i_liquidityDeadline;

    // ───────────────────────────── Fee ───────────────────────────
    /// @notice Maximum service-fee cap (bps) ensuring fee ≤ balance × cap.
    uint24 private immutable i_maxServiceFeeRate;

    /// @notice Fixed processing fee (in WETH) paid to the fee-collecting address.
    uint256 private immutable i_processingFee;

    /// @notice Address that receives protocol-level operational fees.
    address private immutable i_feeCollectingAddress;

    // ─────────────────────────── Scale ───────────────────────────
    /// @notice 1e18 precision base used for normalized price math.
    uint256 private immutable i_precision18;

    /// @notice 1e36 precision base used to invert 1e18-scaled prices without losing precision.
    uint256 private immutable i_precision36;

    /// @notice Basis-point base (1e4 = 100%).
    uint256 private immutable i_basisPointBase;

    // ───────────────────────── Tolerances ────────────────────────
    /// @notice Max allowed spot-vs-TWAP deviation (bps) for liquidity operations.
    uint24 private immutable i_maxSlippageRateLiquidity;

    /// @notice Max allowed spot-vs-TWAP deviation (bps) for swaps.
    uint24 private immutable i_maxSlippageRateSwap;

    /// @notice Virtual liquidity used for TWAP stability calculations.
    uint128 private immutable i_virtualLiquidity;

    /// @notice TWAP observation window for liquidity operations (in seconds).
    uint32 private immutable i_twapSecondsLiquidity;

    /// @notice TWAP observation window for swap pricing (in seconds).
    uint32 private immutable i_twapSecondsSwap;

    /*//////////////////////////////////////////////////////////////
                                 STRUCT
    //////////////////////////////////////////////////////////////*/

    /// @dev Reusable container for TWAP/tick context to keep stack shallow and logic explicit. `twapPriceX1e18` is token1/token0 priced
    ///      at 1e18 scale.
    struct TWAPContext {
        uint160 avgSqrtPriceX96;
        uint256 twapPriceX1e18; // token1 in token0 units × 1e18
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtRatioAX96;
        uint160 sqrtRatioBX96;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes immutable configuration and validates the Uniswap position/invariants.
     * @param configAddress_        Birdieswap config contract address (non-zero)
     * @param blpTokenAddress_      Birdieswap DualVault (also the LP ERC20 address, non-zero)
     * @param tokenId_              Uniswap V3 position tokenId for this vault/strategy pair
     * @param poolAddress_          Uniswap V3 pool backing the position
     * @param feeCollectingAddress_ Address that receives protocol fee in WETH
     * @param eventRelayerAddress_  Protocol event relayer (non-zero)
     *
     * @dev bTokens are ordered deterministically to maintain a consistent (token0, token1) view. The Router is protocol-owned and trusted;
     *      granting max allowance is an intentional gas optimization. Reverts if the position NFT is not minted.
     *
     *      Invariants checked:
     *        • Pool tokens match the bTokens (in either order)
     *        • NFT tokens match the pool’s tokens (in either order)
     *        • NFT fee tier corresponds to the factory pool for (token0, token1, fee)
     */
    constructor(
        address configAddress_,
        address blpTokenAddress_,
        uint256 tokenId_,
        address poolAddress_,
        address feeCollectingAddress_,
        address eventRelayerAddress_
    ) {
        // ────────────────── Input validation ─────────────────────
        if (configAddress_ == address(0)) revert BirdieswapDualStrategyV1__ZeroAddressNotAllowed();
        if (blpTokenAddress_ == address(0)) revert BirdieswapDualStrategyV1__ZeroAddressNotAllowed();
        if (eventRelayerAddress_ == address(0)) revert BirdieswapDualStrategyV1__ZeroAddressNotAllowed();
        if (poolAddress_ == address(0)) revert BirdieswapDualStrategyV1__InvalidConfiguration();
        if (feeCollectingAddress_ == address(0)) revert BirdieswapDualStrategyV1__InvalidConfiguration();

        // ─────────────────── Config & relayer ────────────────────
        BirdieswapConfigV1 config = BirdieswapConfigV1(configAddress_);
        i_event = IBirdieswapEventRelayerV1(eventRelayerAddress_);

        // ─────────────────────── Tokens ──────────────────────────
        IBirdieswapDualVaultV1 blpToken = IBirdieswapDualVaultV1(blpTokenAddress_);
        (address bToken0, address bToken1) = (blpToken.getToken0Address(), blpToken.getToken1Address());

        // Order bTokens deterministically and assign immutables
        (bToken0 > bToken1) ? (bToken0, bToken1) = (bToken1, bToken0) : (bToken0, bToken1) = (bToken0, bToken1);
        if (bToken0 == bToken1) revert BirdieswapDualStrategyV1__InvalidConfiguration();

        (i_bToken0Address, i_bToken1Address) = (bToken0, bToken1);
        i_blpTokenAddress = blpTokenAddress_;

        // ─────────────────────── Uniswap ─────────────────────────
        i_tokenId = tokenId_;
        i_poolAddress = poolAddress_;
        i_positionManagerAddress = config.i_uniswapV3PositionManager();
        i_uniswapFactoryAddress = config.i_uniswapV3Factory();
        i_liquidityDeadline = config.i_liquidityDeadline();
        i_maxSlippageRateLiquidity = config.i_maxSlippageRateLiquidity();
        i_maxSlippageRateSwap = config.i_maxSlippageRateSwap();
        i_virtualLiquidity = config.i_virtualLiquidity();
        i_twapSecondsLiquidity = config.i_twapSecondsLiquidity();
        i_twapSecondsSwap = config.i_twapSecondsSwap();

        // ─────────────────────── Fees ────────────────────────────
        i_wethAddress = config.i_weth();
        i_feeCollectingAddress = feeCollectingAddress_;
        i_maxServiceFeeRate = config.i_maxServiceFeeRate();
        i_processingFee = config.i_processingFee();

        // ─────────────────────── Math base ───────────────────────
        i_precision18 = config.PRECISION_18();
        i_precision36 = config.PRECISION_36();
        i_basisPointBase = config.BASIS_POINT_BASE();

        // ───────────────── NFT & pool validation ─────────────────
        // Ensure NFT is minted and owned by a valid address
        try INonfungiblePositionManager(i_positionManagerAddress).ownerOf(i_tokenId) returns (address owner) {
            if (owner == address(0)) revert BirdieswapDualStrategyV1__NFTNotMinted();
        } catch {
            revert BirdieswapDualStrategyV1__NFTNotMinted();
        }

        // Pool tokens must match configured bTokens
        address p0 = IUniswapV3Pool(i_poolAddress).token0();
        address p1 = IUniswapV3Pool(i_poolAddress).token1();
        bool poolMatches = (p0 == i_bToken0Address && p1 == i_bToken1Address) || (p0 == i_bToken1Address && p1 == i_bToken0Address);
        if (!poolMatches) revert BirdieswapDualStrategyV1__PoolTokensMismatch();

        // NFT tokens must match pool tokens
        (,, address n0, address n1, uint24 nftFee,,,,,,,) = INonfungiblePositionManager(i_positionManagerAddress).positions(i_tokenId);
        bool nftMatches = (n0 == p0 && n1 == p1) || (n0 == p1 && n1 == p0);
        if (!nftMatches) revert BirdieswapDualStrategyV1__NFTTokensMismatch();

        // NFT fee tier must correspond to factory-registered pool
        address factoryPool = IUniswapV3Factory(i_uniswapFactoryAddress).getPool(p0, p1, nftFee);
        if (factoryPool != i_poolAddress) revert BirdieswapDualStrategyV1__PoolAndFeeTierMismatch();
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts callable entrypoints to the configured DualVault only.
     * @dev    Prevents any external/untrusted caller from invoking strategy actions.
     */
    modifier onlyDualVault() {
        if (msg.sender != i_blpTokenAddress) revert BirdieswapDualStrategyV1__OnlyDualVaultCanCall();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the contract version.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /**
     * @notice Returns the Uniswap V3 position tokenId managed for this vault/strategy pair.
     */
    function getTokenId() external view returns (uint256) {
        return i_tokenId;
    }

    /**
     * @notice Returns the Uniswap V3 PositionManager address.
     */
    function getPositionManagerAddress() external view returns (address) {
        return i_positionManagerAddress;
    }

    /**
     * @notice Returns the associated DualVault address.
     */
    function getDualVaultAddress() external view returns (address) {
        return i_blpTokenAddress;
    }

    /**
     * @notice Returns the underlying Uniswap V3 pool address.
     */
    function getPoolAddress() external view returns (address) {
        return i_poolAddress;
    }

    /**
     * @notice Returns the Uniswap V3 fee tier (500/3000/10000) of the managed position.
     * @dev    Used for swap routing and pool identification (not a protocol fee).
     */
    function getFeeTier() external view returns (uint24) {
        (,,,, uint24 feeTier,,,,,,,) = INonfungiblePositionManager(i_positionManagerAddress).positions(i_tokenId);
        return feeTier;
    }

    /**
     * @notice Returns the current Uniswap V3 liquidity (uint128) of the position as uint256.
     * @dev    Reported as uint256 for alignment with ERC4626-style accounting in the DualVault.
     */
    function getPositionLiquidity() external view returns (uint256) {
        return _getPositionLiquidity();
    }

    /**
     * @notice Returns the instantaneous (spot) bToken composition of the position.
     * @dev    Uses pool `slot0` (no TWAP). Intended for visibility/accounting and subject to short-term volatility.
     * @return token0Addr  Address of bToken0
     * @return token1Addr  Address of bToken1
     * @return amount0     Spot-implied amount of bToken0
     * @return amount1     Spot-implied amount of bToken1
     */
    function getPositionComposition() external view returns (address, address, uint256, uint256) {
        (uint256 bToken0Amount, uint256 bToken1Amount) = _getSpotTokenAmounts();

        return (i_bToken0Address, i_bToken1Address, bToken0Amount, bToken1Amount);
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL ENTRYPOINTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds liquidity to the Uniswap V3 position using bTokens pulled from the DualVault.
     * @dev    TWAP ratio validation guards against price manipulation; spot/TWAP deviation must be within `i_maxSlippageRateLiquidity`.
     *         Any unused bTokens are returned to the DualVault.
     * @param  _bToken0Amount Amount of bToken0 supplied by the DualVault
     * @param  _bToken1Amount Amount of bToken1 supplied by the DualVault
     * @return liquidity      Liquidity added to the Uniswap position
     * @return                Unused bToken0 returned to the DualVault
     * @return                Unused bToken1 returned to the DualVault
     */
    function deposit(uint256 _bToken0Amount, uint256 _bToken1Amount)
        external
        onlyDualVault
        nonReentrant
        returns (uint256, uint256, uint256)
    {
        _checkDepositBalanceLimits(_bToken0Amount, _bToken1Amount);
        _assertDualVaultOwnsPosition();

        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);

        // The NFT never leaves the DualVault; only its internal liquidity changes through this Strategy.
        bToken0.forceApprove(i_positionManagerAddress, _bToken0Amount);
        bToken1.forceApprove(i_positionManagerAddress, _bToken1Amount);

        (uint256 liquidity, uint256 depositAmount0, uint256 depositAmount1) = _increaseLiquidity(_bToken0Amount, _bToken1Amount);

        bToken0.forceApprove(i_positionManagerAddress, 0);
        bToken1.forceApprove(i_positionManagerAddress, 0);

        if (depositAmount0 < _bToken0Amount) bToken0.safeTransfer(msg.sender, (_bToken0Amount - depositAmount0));
        if (depositAmount1 < _bToken1Amount) bToken1.safeTransfer(msg.sender, (_bToken1Amount - depositAmount1));

        return (liquidity, (_bToken0Amount - depositAmount0), (_bToken1Amount - depositAmount1));
    }

    /**
     * @notice Redeem liquidity back into bTokens for the DualVault.
     * @dev    TWAP safety check ensures current price is close to TWAP. Min amounts are derived from TWAP.
     * @param  _blpTokenAmount Liquidity (Uniswap units) to redeem.
     * @return                 Amounts of bToken0 and bToken1 returned to the DualVault.
     */
    function redeem(uint256 _blpTokenAmount) external onlyDualVault nonReentrant returns (uint256, uint256) {
        return _redeem(_blpTokenAmount);
    }

    /**
     * @notice Harvest fees, pay the fixed WETH processing fee to ops multisig, rebalance and compound.
     * @dev    Keeper-triggered. Swaps use the Router at the pool’s fee tier. TWAP guards apply to swap minOut.
     * @return New Uniswap liquidity added post-compounding.
     *
     * @dev The fixed i_processingFee may cause revert when insufficient WETH is harvested, but this is intentional. Only the DualVault can
     *      trigger doHardWork(), and the off-chain keeper logic ensures sufficient accrued WETH before invoking it. Thus, this cannot cause
     *      user-facing DoS or affect normal deposits/redeems.
     */
    function doHardWork() external onlyDualVault nonReentrant returns (uint256) {
        _assertDualVaultOwnsPosition();

        _collect(type(uint128).max, type(uint128).max);

        IBirdieswapRouterV1 router = IBirdieswapRouterV1(IBirdieswapDualVaultV1(i_blpTokenAddress).getRouterAddress());
        address underlyingToken0Address = router.getUnderlyingTokenAddress(i_bToken0Address);
        address underlyingToken1Address = router.getUnderlyingTokenAddress(i_bToken1Address);
        if (underlyingToken0Address == address(0) || underlyingToken1Address == address(0)) {
            revert BirdieswapDualStrategyV1__RouterMappingMissing();
        }
        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);
        uint256 bToken0Amount = bToken0.balanceOf(address(this));
        uint256 bToken1Amount = bToken1.balanceOf(address(this));

        // Swap each token to WETH when the underlying is not WETH.
        if (bToken0Amount > 0) _redeemToUnderlyingAndSwapToWETH(i_bToken0Address, bToken0Amount);
        if (bToken1Amount > 0) _redeemToUnderlyingAndSwapToWETH(i_bToken1Address, bToken1Amount);

        uint256 wethFeePaid = _transferOpsFeeOrRevert();

        uint256 remainingWETH = IERC20(i_wethAddress).balanceOf(address(this));
        if (remainingWETH > 0) {
            uint24 feeTier = IBirdieswapDualVaultV1(i_blpTokenAddress).getFeeTier();
            (uint256 wethFor0, uint256 wethFor1) = _allocateWETHByTWAPWeights(i_bToken0Address, i_bToken1Address, feeTier, remainingWETH);

            // Swap WETH back into underlyings and deposit to SingleVaults, yielding new bTokens.
            _swapWETHToBTokenAndSingleDeposit(underlyingToken0Address, i_bToken0Address, wethFor0);
            _swapWETHToBTokenAndSingleDeposit(underlyingToken1Address, i_bToken1Address, wethFor1);
        }

        // Add liquidity again using any newly minted bTokens.
        uint256 liquidity;
        {
            uint256 bToken0Remaining = IERC20(i_bToken0Address).balanceOf(address(this));
            uint256 bToken1Remaining = IERC20(i_bToken1Address).balanceOf(address(this));

            if ((bToken0Remaining == 0) && (bToken1Remaining == 0)) {
                try i_event.emitDualHardWork(0, bToken0Amount, bToken1Amount, wethFeePaid) { } catch { }
                _assertDualVaultOwnsPosition();
                return 0;
            }
            bToken0.forceApprove(i_positionManagerAddress, bToken0Remaining);
            bToken1.forceApprove(i_positionManagerAddress, bToken1Remaining);
            (liquidity,,) = _increaseLiquidity(bToken0Remaining, bToken1Remaining);
            bToken0.forceApprove(i_positionManagerAddress, 0);
            bToken1.forceApprove(i_positionManagerAddress, 0);
        }
        try i_event.emitDualHardWork(liquidity, bToken0Amount, bToken1Amount, wethFeePaid) { } catch { }

        _assertDualVaultOwnsPosition();

        return liquidity;
    }

    /**
     * @notice Emergency procedure: remove all liquidity; NFT remains in the DualVault.
     * @dev    For severe/rare incidents only. After execution, a new strategy/pool is typically deployed.
     *         Collects fees, returns all balances to the DualVault, and emits `EmergencyExit`.
     */
    function emergencyExit() external onlyDualVault nonReentrant returns (uint256, uint256) {
        _assertDualVaultOwnsPosition();

        uint256 liquidity = _getPositionLiquidity();
        if (liquidity == 0) revert BirdieswapDualStrategyV1__NoLiquidityLeftToWithdraw();
        _redeem(liquidity);
        _collect(type(uint128).max, type(uint128).max);

        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);
        uint256 bToken0Amount = bToken0.balanceOf(address(this));
        uint256 bToken1Amount = bToken1.balanceOf(address(this));
        bToken0.safeTransfer(i_blpTokenAddress, bToken0Amount);
        bToken1.safeTransfer(i_blpTokenAddress, bToken1Amount);

        try i_event.emitDualEmergencyExit(bToken0Amount, bToken1Amount) { } catch { }

        _assertDualVaultOwnsPosition();

        return (bToken0Amount, bToken1Amount);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE INTERNAL FLOW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds liquidity with TWAP ratio validation and drift guard.
     * @dev    Sets min amounts as a slippage-bounded fraction of desired inputs.
     * @param  _bToken0Amount Desired bToken0.
     * @param  _bToken1Amount Desired bToken1.
     * @return liquidity      Liquidity added.
     * @return depositAmount0 Actual amount0 used.
     * @return depositAmount1 Actual amount1 used.
     */
    function _increaseLiquidity(uint256 _bToken0Amount, uint256 _bToken1Amount) private returns (uint256, uint256, uint256) {
        if (_bToken0Amount == 0 || _bToken1Amount == 0) revert BirdieswapDualStrategyV1__InvalidDepositAmount();
        _assertDualVaultOwnsPosition();

        TWAPContext memory ctx = _buildTWAPContext(_bToken0Amount, _bToken1Amount, true);

        (uint160 spotSqrt,,,,,,) = IUniswapV3Pool(i_poolAddress).slot0();
        uint256 spot = _priceX1e18FromSqrt(spotSqrt);
        _ensureDeviationWithin(spot, ctx.twapPriceX1e18, i_maxSlippageRateLiquidity);

        uint256 min0 = Math.mulDiv(_bToken0Amount, i_basisPointBase - i_maxSlippageRateLiquidity, i_basisPointBase);
        uint256 min1 = Math.mulDiv(_bToken1Amount, i_basisPointBase - i_maxSlippageRateLiquidity, i_basisPointBase);
        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: i_tokenId,
            amount0Desired: _bToken0Amount,
            amount1Desired: _bToken1Amount,
            amount0Min: min0,
            amount1Min: min1,
            deadline: block.timestamp + i_liquidityDeadline
        });

        uint256 preLiquidity = _getPositionLiquidity();
        (uint256 liquidity, uint256 depositAmount0, uint256 depositAmount1) =
            INonfungiblePositionManager(i_positionManagerAddress).increaseLiquidity(params);
        uint256 postLiquidity = _getPositionLiquidity();
        if (postLiquidity <= preLiquidity || postLiquidity - preLiquidity != liquidity) {
            revert BirdieswapDualStrategyV1__LiquidityInvariantMismatch();
        }

        _assertDualVaultOwnsPosition();

        return (liquidity, depositAmount0, depositAmount1);
    }

    /**
     * @notice Removes liquidity with TWAP deviation checks and tick-aware mins.
     * @dev    Computes expected token amounts at TWAP and sets slippage-bounded minimums.
     * @param  _blpTokenAmount Liquidity to remove (Uniswap units).
     * @return bToken0Amount   Amount of token0 withdrawn.
     * @return bToken1Amount   Amount of token1 withdrawn.
     */
    function _decreaseLiquidity(uint256 _blpTokenAmount) private returns (uint256, uint256) {
        if (_blpTokenAmount == 0) revert BirdieswapDualStrategyV1__InvalidLiquidityAmount();
        _assertDualVaultOwnsPosition();

        TWAPContext memory ctx = _buildTWAPContext(0, 0, false);

        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(i_poolAddress).slot0();
        uint256 scaledCurrent = _priceX1e18FromSqrt(currentSqrtPriceX96);
        _ensureDeviationWithin(scaledCurrent, ctx.twapPriceX1e18, i_maxSlippageRateLiquidity);

        (uint256 exp0, uint256 exp1) =
            LiquidityAmounts.getAmountsForLiquidity(ctx.avgSqrtPriceX96, ctx.sqrtRatioAX96, ctx.sqrtRatioBX96, _toUint128(_blpTokenAmount));

        uint256 min0 = Math.mulDiv(exp0, i_basisPointBase - i_maxSlippageRateLiquidity, i_basisPointBase);
        uint256 min1 = Math.mulDiv(exp1, i_basisPointBase - i_maxSlippageRateLiquidity, i_basisPointBase);
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: i_tokenId,
            liquidity: _toUint128(_blpTokenAmount),
            amount0Min: min0,
            amount1Min: min1,
            deadline: block.timestamp + i_liquidityDeadline
        });

        (uint256 bToken0Amount, uint256 bToken1Amount) = INonfungiblePositionManager(i_positionManagerAddress).decreaseLiquidity(params);

        // Final ratio sanity check vs TWAP
        if (bToken0Amount > 0 && bToken1Amount > 0) {
            uint256 actualRatio = Math.mulDiv(bToken1Amount, i_precision18, bToken0Amount);
            uint256 lower = Math.mulDiv(ctx.twapPriceX1e18, i_basisPointBase - i_maxSlippageRateLiquidity, i_basisPointBase);
            uint256 upper = Math.mulDiv(ctx.twapPriceX1e18, i_basisPointBase + i_maxSlippageRateLiquidity, i_basisPointBase);
            if (actualRatio < lower || actualRatio > upper) revert BirdieswapDualStrategyV1__TWAPDeviationExceeded();
        }

        _assertDualVaultOwnsPosition();

        return (bToken0Amount, bToken1Amount);
    }

    /**
     * @notice Internal redemption: decrease liquidity (TWAP-gated) and return bTokens to the DualVault.
     * @param  _blpTokenAmount Liquidity to redeem (Uniswap units).
     * @return                 (bToken0Amount, bToken1Amount) returned to the DualVault.
     */
    function _redeem(uint256 _blpTokenAmount) private returns (uint256, uint256) {
        (uint256 bToken0Amount, uint256 bToken1Amount) = _decreaseLiquidity(_blpTokenAmount);

        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);
        bToken0.safeTransfer(i_blpTokenAddress, bToken0Amount);
        bToken1.safeTransfer(i_blpTokenAddress, bToken1Amount);

        return (bToken0Amount, bToken1Amount);
    }

    /**
     * @notice Collects pending fees (and any owed tokens) from Uniswap V3 to this strategy.
     * @param  _bToken0Amount Max amount0 to collect.
     * @param  _bToken1Amount Max amount1 to collect.
     * @return                (amount0, amount1) actually collected.
     */
    function _collect(uint256 _bToken0Amount, uint256 _bToken1Amount) private returns (uint256, uint256) {
        _assertDualVaultOwnsPosition();

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: i_tokenId,
            recipient: address(this),
            amount0Max: _toUint128(_bToken0Amount),
            amount1Max: _toUint128(_bToken1Amount)
        });
        (uint256 bToken0Amount, uint256 bToken1Amount) = INonfungiblePositionManager(i_positionManagerAddress).collect(params);

        _assertDualVaultOwnsPosition();

        return (bToken0Amount, bToken1Amount);
    }

    /**
     * @notice Pays the fixed operational fee (e.g., 0.01 WETH) to the i_feeCollectingAddress, enforcing fee cap policy.
     * @dev    Reverts if WETH balance × cap < i_processingFee (i.e., insufficient funds under fee cap).
     */
    function _transferOpsFeeOrRevert() private returns (uint256) {
        uint256 wethAmount = IERC20(i_wethAddress).balanceOf(address(this));
        if (Math.mulDiv(wethAmount, i_maxServiceFeeRate, i_basisPointBase) < i_processingFee) {
            revert BirdieswapDualStrategyV1__InsufficientWETHForProcessingFee();
        }
        IERC20(i_wethAddress).safeTransfer(i_feeCollectingAddress, i_processingFee);

        return i_processingFee;
    }

    /*//////////////////////////////////////////////////////////////
                            VALIDATION & SAFETY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate non-zero deposit amounts and sufficient local balances.
     * @param  _bToken0Amount Desired bToken0 deposit amount.
     * @param  _bToken1Amount Desired bToken1 deposit amount.
     */
    function _checkDepositBalanceLimits(uint256 _bToken0Amount, uint256 _bToken1Amount) private view {
        if (_bToken0Amount > IERC20(i_bToken0Address).balanceOf(address(this))) {
            revert BirdieswapDualStrategyV1__DepositAmountExceedsBalance();
        }
        if (_bToken1Amount > IERC20(i_bToken1Address).balanceOf(address(this))) {
            revert BirdieswapDualStrategyV1__DepositAmountExceedsBalance();
        }
    }

    /**
     * @notice Ensures that the Uniswap position NFT remains owned by the DualVault.
     * @dev    Called before and after liquidity or fee operations to confirm custody.
     *         Reverts if the NFT has been transferred or approval was revoked.
     */
    function _assertDualVaultOwnsPosition() private view {
        if (INonfungiblePositionManager(i_positionManagerAddress).ownerOf(i_tokenId) != address(i_blpTokenAddress)) {
            revert BirdieswapDualStrategyV1__PositionNotOwnedByDualVault();
        }
    }

    /**
     * @notice Safely cast a uint256 down to uint128.
     * @dev    Used when interacting with Uniswap V3 liquidity APIs that require uint128.
     *         Reverts on overflow to preserve arithmetic integrity.
     * @param  x The uint256 value to downcast.
     * @return y The safely downcasted uint128 value.
     */
    function _toUint128(uint256 x) internal pure returns (uint128 y) {
        if (x > type(uint128).max) revert BirdieswapDualStrategyV1__Uint128Overflow();

        return uint128(x);
    }

    /*//////////////////////////////////////////////////////////////
                            TWAP & PRICE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Converts sqrtPriceX96 to a 1e18-scaled price ratio (token1/token0).
     * @dev    price = (sqrtPrice^2 / 2^192) × 1e18.
     *         Implemented as `mulDiv(sqrt, sqrt×1e18, 2^192)` to avoid 256-bit overflow.
     */
    function _priceX1e18FromSqrt(uint160 _sqrtPrice) internal view returns (uint256) {
        // price(1e18-scale) = (sqrt^2 / 2^192) * 1e18
        // Compute as mulDiv(sqrt, sqrt * 1e18, 2^192) to avoid 256-bit overflow on sqrt^2.
        uint256 s = uint256(_sqrtPrice);
        uint256 y = s * i_precision18; // MAX_SQRT_RATIO * 1e18 < 2^256, safe

        // Uses 512-bit mul internally; returns floor( (s * y) / 2^192 )
        return Math.mulDiv(s, y, (uint256(1) << 192));
    }

    /**
     * @notice Observe the average sqrtPriceX96 from a Uniswap V3 pool.
     * @dev    Common utility used by TWAP-related functions.
     * @param  _pool        The Uniswap V3 pool to observe.
     * @param  _secondsAgo  Lookback window for TWAP calculation.
     * @return avgSqrtPriceX96  The average sqrtPriceX96 during the lookback window.
     */
    function _observeAverageSqrtPrice(IUniswapV3Pool _pool, uint32 _secondsAgo) private view returns (uint160 avgSqrtPriceX96) {
        uint32[] memory secs = new uint32[](2);
        secs[0] = _secondsAgo;
        secs[1] = 0;

        (int56[] memory tickCumulatives,) = _pool.observe(secs);
        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDelta / int56(uint56(_secondsAgo)));
        // Round toward negative infinity (Uniswap standard)
        if (tickDelta < 0 && (tickDelta % int56(uint56(_secondsAgo)) != 0)) avgTick--;
        avgSqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);

        return avgSqrtPriceX96;
    }

    /**
     * @notice Returns TWAP and spot price ratios (tokenOut/tokenIn × 1e18).
     * @dev    Reuses _observeAverageSqrtPrice() for TWAP observation.
     */
    function _getTWAPAndSpotX1e18(address _tokenIn, address _tokenOut, address _poolAddress, uint32 _secondsAgo)
        private
        view
        returns (uint256 twapX1e18, uint256 spotX1e18)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(_poolAddress);
        // Check the average sqrtPriceX96 (TWAP) of the vault’s pool.
        uint160 twapSqrtX96 = _observeAverageSqrtPrice(pool, _secondsAgo);
        (uint160 spotSqrtX96,,,,,,) = pool.slot0();

        uint256 priceTWAP = _priceX1e18FromSqrt(twapSqrtX96);
        uint256 priceSpot = _priceX1e18FromSqrt(spotSqrtX96);

        if (_tokenIn == pool.token0() && _tokenOut == pool.token1()) {
            (twapX1e18, spotX1e18) = (priceTWAP, priceSpot);
        } else if (_tokenIn == pool.token1() && _tokenOut == pool.token0()) {
            (twapX1e18, spotX1e18) = (_invertScaledPrice(priceTWAP), _invertScaledPrice(priceSpot));
        } else {
            revert BirdieswapDualStrategyV1__InvalidTokensForTWAP();
        }

        return (twapX1e18, spotX1e18);
    }

    /**
     * @notice Build TWAP + tick range context; optionally validate provided ratio against TWAP.
     * @dev    Centralized helper used by add/remove liquidity paths.
     * @param  _bToken0Amount Amount of bToken0 (only relevant if `_validateRatio == true`).
     * @param  _bToken1Amount Amount of bToken1 (only relevant if `_validateRatio == true`).
     * @param  _validateRatio Whether to validate the provided ratio vs TWAP bounds.
     * @return context        Packed struct with TWAP, scaled price, and range sqrt ratios.
     */
    function _buildTWAPContext(uint256 _bToken0Amount, uint256 _bToken1Amount, bool _validateRatio)
        private
        view
        returns (TWAPContext memory)
    {
        TWAPContext memory context;
        // Check the average sqrtPriceX96 (TWAP) of the vault’s pool.
        context.avgSqrtPriceX96 = _observeAverageSqrtPrice(IUniswapV3Pool(i_poolAddress), i_twapSecondsLiquidity);

        (,,,,, context.tickLower, context.tickUpper,,,,,) = INonfungiblePositionManager(i_positionManagerAddress).positions(i_tokenId);
        context.sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(context.tickLower);
        context.sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(context.tickUpper);

        context.twapPriceX1e18 = _priceX1e18FromSqrt(context.avgSqrtPriceX96);

        if (_validateRatio) {
            uint256 expectedToken1 = Math.mulDiv(_bToken0Amount, context.twapPriceX1e18, i_precision18);
            uint256 lower = Math.mulDiv(expectedToken1, i_basisPointBase - i_maxSlippageRateLiquidity, i_basisPointBase);
            uint256 upper = Math.mulDiv(expectedToken1, i_basisPointBase + i_maxSlippageRateLiquidity, i_basisPointBase);
            if (_bToken1Amount < lower || _bToken1Amount > upper) revert BirdieswapDualStrategyV1__TWAPDeviationExceeded();
        }

        return context;
    }

    /**
     * @notice Get TWAP WETH→token prices (1e18 scale) for two bTokens.
     * @dev    If a bToken corresponds to WETH itself (bWETH), there is no WETH/WETH pool; derive a synthetic TWAP price from the
     *         SingleVault’s ERC4626 exchange rate via `previewDeposit(1e18)` and normalize to 1e18. Otherwise, read Uniswap V3 TWAP
     *         directly. Returns prices normalized to 1e18 (tokenOut per 1 WETH).
     */
    function _fetchWETHTWAPPrices(address _bToken0Address, address _bToken1Address, uint24 _feeTier, uint32 _secondsAgo)
        private
        view
        returns (uint256, uint256)
    {
        IBirdieswapRouterV1 router = IBirdieswapRouterV1(IBirdieswapDualVaultV1(i_blpTokenAddress).getRouterAddress());
        address wethBTokenAddress = router.getBTokenAddress(i_wethAddress);
        if (wethBTokenAddress == address(0)) revert BirdieswapDualStrategyV1__RouterMappingMissing();

        uint256 twapWETHTo0;
        uint256 twapWETHTo1;

        // ──────────────────────── Token0 ─────────────────────────
        if (_bToken0Address == wethBTokenAddress) {
            // WETH decimals are 18. previewDeposit expects ASSET units, not share units.
            uint256 shares = BirdieswapSingleVaultV1(_bToken0Address).previewDeposit(i_precision18);
            if (shares == 0) revert BirdieswapDualStrategyV1__InvalidTokensForTWAP();

            // Normalize to 1e18 scale: shares per asset unit
            // twapWETHTo0 = (shares / 10**assetDecimals) * 1e18
            twapWETHTo0 = Math.mulDiv(shares, i_precision18, i_precision18);
        } else {
            address pool0 = _resolvePoolAddress(wethBTokenAddress, _bToken0Address, _feeTier);
            (twapWETHTo0,) = _getTWAPAndSpotX1e18(wethBTokenAddress, _bToken0Address, pool0, _secondsAgo);
        }

        // ──────────────────────── Token1 ─────────────────────────
        if (_bToken1Address == wethBTokenAddress) {
            // WETH decimals are 18. previewDeposit expects ASSET units, not share units.
            uint256 shares = BirdieswapSingleVaultV1(_bToken1Address).previewDeposit(i_precision18);
            if (shares == 0) revert BirdieswapDualStrategyV1__InvalidTokensForTWAP();

            twapWETHTo1 = Math.mulDiv(shares, i_precision18, i_precision18);
        } else {
            address pool1 = _resolvePoolAddress(wethBTokenAddress, _bToken1Address, _feeTier);
            (twapWETHTo1,) = _getTWAPAndSpotX1e18(wethBTokenAddress, _bToken1Address, pool1, _secondsAgo);
        }

        return (twapWETHTo0, twapWETHTo1);
    }

    /**
     * @notice Compute a TWAP-weighted WETH split for rebalancing between token0 and token1.
     * @dev    Avoids naive 50/50 by weighting by (estimated range composition × TWAP price).
     * @param  _bToken0Address Address of bToken0
     * @param  _bToken1Address Address of bToken1
     * @param  _feeTier        Uniswap fee tier used for price reads
     * @param  _totalWETH      Total WETH to split
     * @return wethForToken0   WETH allocated to token0 side
     * @return wethForToken1   WETH allocated to token1 side
     */
    function _allocateWETHByTWAPWeights(address _bToken0Address, address _bToken1Address, uint24 _feeTier, uint256 _totalWETH)
        private
        view
        returns (uint256, uint256)
    {
        uint256 wethForToken0;
        uint256 wethForToken1;

        (uint256 estimated0, uint256 estimated1) = _estimateRangeComposition();
        (uint256 twapWETHTo0, uint256 twapWETHTo1) = _fetchWETHTWAPPrices(_bToken0Address, _bToken1Address, _feeTier, i_twapSecondsSwap);

        uint256 v0 = (twapWETHTo0 == 0) ? 0 : Math.mulDiv(estimated0, i_precision18, twapWETHTo0);
        uint256 v1 = (twapWETHTo1 == 0) ? 0 : Math.mulDiv(estimated1, i_precision18, twapWETHTo1);
        uint256 sum = v0 + v1;
        if (sum == 0) {
            // Fallback: split evenly if price signals are unavailable.
            wethForToken0 = _totalWETH / 2;
            wethForToken1 = _totalWETH - wethForToken0;
        } else {
            wethForToken0 = Math.mulDiv(_totalWETH, v0, sum);
            wethForToken1 = _totalWETH - wethForToken0;
        }

        return (wethForToken0, wethForToken1);
    }

    /**
     * @notice Estimate relative token0/token1 composition around current TWAP and tick range.
     * @dev    Uses a small virtual liquidity to derive proportions; used to split WETH for rebalancing.
     * @return estimated0 Estimated proportion of token0.
     * @return estimated1 Estimated proportion of token1.
     */
    function _estimateRangeComposition() private view returns (uint256, uint256) {
        // Check the average sqrtPriceX96 (TWAP) of the vault’s pool.
        uint160 twapSqrt = _observeAverageSqrtPrice(IUniswapV3Pool(i_poolAddress), i_twapSecondsLiquidity);

        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = INonfungiblePositionManager(i_positionManagerAddress).positions(i_tokenId);

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);

        // Use a small virtual liquidity (1e5) to get relative amounts.
        (uint256 estimated0, uint256 estimated1) = LiquidityAmounts.getAmountsForLiquidity(twapSqrt, sqrtA, sqrtB, i_virtualLiquidity);

        return (estimated0, estimated1);
    }

    /**
     * @notice Invert a 1e18-scaled price ratio.
     * @dev    Returns 1 / p scaled by 1e18. Reverts if p == 0.
     */
    function _invertScaledPrice(uint256 p) private view returns (uint256) {
        if (p == 0) revert BirdieswapDualStrategyV1__InvalidPriceForTWAP();
        return Math.mulDiv(i_precision36, 1, p);
    }

    /**
     * @notice Compute drift (basis points) between spot and TWAP prices.
     * @dev    Returns |spot - twap| / twap × i_basisPointBase.
     */
    function _calculateTWAPDriftBps(uint256 _spotX1e18, uint256 _twapX1e18) private view returns (uint256 diff) {
        if (_twapX1e18 == 0) revert BirdieswapDualStrategyV1__InvalidPriceForTWAP();
        unchecked {
            diff = _spotX1e18 > _twapX1e18 ? _spotX1e18 - _twapX1e18 : _twapX1e18 - _spotX1e18;
        }
        return Math.mulDiv(diff, i_basisPointBase, _twapX1e18);
    }

    /**
     * @notice Enforce maximum deviation between spot and TWAP prices.
     * @param  _spotX1e18   Spot price (1e18-scaled).
     * @param  _twapX1e18   TWAP price (1e18-scaled).
     * @param  _maxDriftBps Max deviation in bps (1 bps = 0.01%)
     */
    function _ensureDeviationWithin(uint256 _spotX1e18, uint256 _twapX1e18, uint24 _maxDriftBps) private view {
        uint256 drift = _calculateTWAPDriftBps(_spotX1e18, _twapX1e18);
        if (drift > _maxDriftBps) revert BirdieswapDualStrategyV1__TWAPDeviationExceeded();
    }

    /**
     * @notice Derives a conservative minOut using TWAP (1e18-scaled) and a slippage cap.
     * @param  _amountIn   Amount of tokenIn
     * @param  _twapX1e18  TWAP price ratio (tokenOut/tokenIn × 1e18)
     * @param  _maxSlipBps Max allowed negative slippage (basis points)
     * @return minOut      Minimum acceptable amountOut
     */
    function _minOutFromTWAP(uint256 _amountIn, uint256 _twapX1e18, uint24 _maxSlipBps) private view returns (uint256 minOut) {
        if (_twapX1e18 == 0) revert BirdieswapDualStrategyV1__InvalidPriceForTWAP();
        uint256 estOut = Math.mulDiv(_amountIn, _twapX1e18, i_precision18);
        minOut = Math.mulDiv(estOut, i_basisPointBase - _maxSlipBps, i_basisPointBase);

        return minOut;
    }

    /**
     * @notice Validates TWAP/spot deviation and derives minOut for swap operations.
     * @param  _tokenIn    Input token address.
     * @param  _tokenOut   Output token address.
     * @param  _amountIn   Amount of tokenIn.
     * @param  _feeTier    Pool fee tier.
     * @return minOut     Minimum acceptable amountOut.
     */
    function _getMinOutWithTWAPGuard(address _tokenIn, address _tokenOut, uint256 _amountIn, uint24 _feeTier, uint32 _secondsAgo)
        private
        view
        returns (uint256 minOut)
    {
        address pool = _resolvePoolAddress(_tokenIn, _tokenOut, _feeTier);

        (uint256 twapX1e18, uint256 spotX1e18) = _getTWAPAndSpotX1e18(_tokenIn, _tokenOut, pool, _secondsAgo);
        if (twapX1e18 == 0 || spotX1e18 == 0) revert BirdieswapDualStrategyV1__InvalidTokensForTWAP();
        _ensureDeviationWithin(spotX1e18, twapX1e18, i_maxSlippageRateSwap);
        minOut = _minOutFromTWAP(_amountIn, twapX1e18, i_maxSlippageRateSwap);

        return minOut;
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP & COMPOSITION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Redeems bTokens to underlying tokens and swaps to WETH if needed under TWAP safeguards.
     *         If the underlying is already WETH, only redemption occurs (no swap).
     * @dev    Fee-On-Transfer (FOT) tokens are NOT supported by protocol policy. If a FOT token were listed, minOut math and accounting
     *         would desync. Governance/Router onboarding MUST prevent FOT listings.
     */
    function _redeemToUnderlyingAndSwapToWETH(address _bTokenAddress, uint256 _bTokenAmount) private {
        IBirdieswapRouterV1 router = IBirdieswapRouterV1(IBirdieswapDualVaultV1(i_blpTokenAddress).getRouterAddress());
        address underlyingTokenAddress = router.getUnderlyingTokenAddress(_bTokenAddress);
        if (underlyingTokenAddress == address(0)) revert BirdieswapDualStrategyV1__RouterMappingMissing();
        uint24 feeTier = IBirdieswapDualVaultV1(i_blpTokenAddress).getFeeTier();

        uint256 bTokenBalanceBefore = IERC20(_bTokenAddress).balanceOf(address(this));
        uint256 underlyingTokenAmount = BirdieswapSingleVaultV1(_bTokenAddress).redeem(_bTokenAmount, address(this), address(this));
        if (underlyingTokenAmount == 0) revert BirdieswapDualStrategyV1__NoUnderlyingReceivedOnRedeem();
        uint256 bTokenBalanceAfter = IERC20(_bTokenAddress).balanceOf(address(this));
        if (bTokenBalanceAfter > bTokenBalanceBefore) revert BirdieswapDualStrategyV1__BTokenRedeemInvariantMismatch();
        if (bTokenBalanceBefore - bTokenBalanceAfter != _bTokenAmount) revert BirdieswapDualStrategyV1__BTokenRedeemInvariantMismatch();

        if (underlyingTokenAddress != i_wethAddress) {
            uint256 minOut =
                _getMinOutWithTWAPGuard(underlyingTokenAddress, i_wethAddress, underlyingTokenAmount, feeTier, i_twapSecondsSwap);
            IERC20(underlyingTokenAddress).forceApprove(address(router), underlyingTokenAmount);
            router.swap(underlyingTokenAddress, feeTier, i_wethAddress, underlyingTokenAmount, minOut, 0, address(this));
            IERC20(underlyingTokenAddress).forceApprove(address(router), 0); // Reset approval
        }
    }

    /**
     * @notice Swap WETH to underlying, deposit into SingleVault, and return minted bTokens.
     * @param  _underlyingTokenAddress Underlying ERC20 address.
     * @param  _bTokenAddress          Target SingleVault address (bToken).
     * @param  _wethAmount             Amount of WETH to convert.
     * @return bTokenAmount            Minted bToken amount from deposit.
     */
    function _swapWETHToBTokenAndSingleDeposit(address _underlyingTokenAddress, address _bTokenAddress, uint256 _wethAmount)
        private
        returns (uint256)
    {
        IBirdieswapRouterV1 router = IBirdieswapRouterV1(IBirdieswapDualVaultV1(i_blpTokenAddress).getRouterAddress());
        uint24 feeTier = IBirdieswapDualVaultV1(i_blpTokenAddress).getFeeTier();
        BirdieswapSingleVaultV1 bTokenVault = BirdieswapSingleVaultV1(_bTokenAddress);
        uint256 bTokenAmount;
        IERC20 weth = IERC20(i_wethAddress);
        IERC20 underlyingToken = IERC20(_underlyingTokenAddress);

        if (_underlyingTokenAddress != i_wethAddress) {
            uint256 minOut = _getMinOutWithTWAPGuard(i_wethAddress, _underlyingTokenAddress, _wethAmount, feeTier, i_twapSecondsSwap);
            weth.forceApprove(address(router), _wethAmount);
            uint256 underlyingTokenAmount =
                router.swap(i_wethAddress, feeTier, _underlyingTokenAddress, _wethAmount, minOut, 0, address(this));
            weth.forceApprove(address(router), 0); // Reset approval
            underlyingToken.forceApprove(_bTokenAddress, underlyingTokenAmount);
            bTokenAmount = bTokenVault.deposit(underlyingTokenAmount, address(this));
            underlyingToken.forceApprove(_bTokenAddress, 0); // Reset approval
        } else {
            underlyingToken.forceApprove(_bTokenAddress, _wethAmount);
            bTokenAmount = bTokenVault.deposit(_wethAmount, address(this));
            underlyingToken.forceApprove(_bTokenAddress, 0); // Reset approval
        }

        return bTokenAmount;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reads current Uniswap position liquidity (uint128) as uint256.
     * @dev    Used by view getters and emergency flow.
     */
    function _getPositionLiquidity() private view returns (uint256) {
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(i_positionManagerAddress).positions(i_tokenId);
        return uint256(liquidity);
    }

    /**
     * @notice Computes the spot (non-TWAP) token amounts represented by the position at current price.
     * @dev    Uses pool `slot0` and `LiquidityAmounts`. Maps Uniswap token order to Birdieswap bToken order.
     * @return position0Amount Spot-implied bToken0 amount.
     * @return position1Amount Spot-implied bToken1 amount.
     */
    function _getSpotTokenAmounts() private view returns (uint256, uint256) {
        (,, address token0,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            INonfungiblePositionManager(i_positionManagerAddress).positions(i_tokenId);
        if (liquidity == 0) return (0, 0);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(i_poolAddress).slot0();
        (uint256 position0Amount, uint256 position1Amount) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );

        if (token0 == i_bToken0Address) return (position0Amount, position1Amount);
        else return (position1Amount, position0Amount);
    }

    /**
     * @notice Resolve Uniswap V3 pool address for the given token pair and fee tier.
     * @dev    Reverts if pool does not exist.
     */
    function _resolvePoolAddress(address _tokenIn, address _tokenOut, uint24 _feeTier) private view returns (address) {
        address poolAddress = IUniswapV3Factory(i_uniswapFactoryAddress).getPool(_tokenIn, _tokenOut, _feeTier);
        if (poolAddress == address(0)) revert BirdieswapDualStrategyV1__PoolNotFound();

        return poolAddress;
    }

    /*//////////////////////////////////////////////////////////////
                            NFT SAFETY HANDLER
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IERC721Receiver
     * @dev Strategy must never take custody of the Uniswap V3 NFT; always reverts.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert BirdieswapDualStrategyV1__NFTTransferNotAccepted();
    }
}
/*//////////////////////////////////////////////////////////////
                          END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant The DualVault always owns the Uniswap V3 position NFT.
/// @custom:invariant Strategy never accepts or transfers ERC721 tokens.
/// @custom:invariant All uint256→uint128 conversions revert on overflow via _toUint128().
