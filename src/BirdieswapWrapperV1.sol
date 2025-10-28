// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { Address } from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "./BirdieswapConfigV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapRouterV1 } from "./interfaces/IBirdieswapRouterV1.sol";

/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/

/**
 * @title IWETH9
 * @notice Minimal canonical interface for Wrapped Ether (WETH9).
 * @dev Extends ERC20 with `deposit()` and `withdraw()`. Used for bridging between native ETH and ERC20 context. WETH9 is immutable,
 *      audited, and reentrancy-safe by design.
 */
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/

/**
 * @title  Birdieswap ETH Wrapper V1
 * @author Birdieswap
 *
 * @notice Canonical ETH entry/exit adapter for the Birdieswap ecosystem. Converts native ETH ↔ WETH for router interactions.
 *         Contains no vault logic and serves purely as a forwarding adapter to the trusted BirdieswapRouterV1.
 *
 * @dev TRUST MODEL
 *      - Router (`i_router`) is a governance-controlled, timelocked upgradeable contract.
 *      - Wrapper assumes router and downstream vaults are non-malicious.
 *      - All privileged actions occur via the router layer only.
 *      - Wrapper itself is immutable and permissionless once deployed.
 *
 * @dev SECURITY DESIGN
 *      • Reentrancy:
 *          - All external mutative functions are `nonReentrant`.
 *          - ETH sends occur only *after* external effects.
 *      • Allowance Policy:
 *          - WETH gets one-time MAX approval at construction.
 *          - Other ERC20s use “lazy MAX approval” (on-demand reset).
 *      • Token Policy:
 *          - Router governance ensures only standard ERC20s (no rebasing, no fee-on-transfer).
 *      • Rescue Policy:
 *          - No recovery function; direct transfers are irrecoverable (“blackholed”).
 *      • Error Philosophy:
 *          - All reverts use explicit custom errors (gas-efficient, traceable).
 *      • Architecture:
 *          - Non-upgradeable, stateless, intended for EOAs (contracts can use WETH directly).
 *
 * @dev CALLBACK / INVOCATION SAFETY
 *      - Router SHALL NEVER perform calls into Wrapper.
 *      - Wrapper SHALL NEVER depend on callbacks from Router/Vaults.
 *      - These invariants preserve CEI and must hold for all Router upgrades.
 *
 * @dev AUDITOR CHECKLIST
 *      1. Router must not call Wrapper externally.
 *      2. Vaults must not callback into Wrapper.
 *      3. Call graph must remain Router → Vault → Strategy → DEX (one-way, synchronous).
 */
contract BirdieswapWrapperV1 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH9;
    using Address for address payable;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Access Control ───────────────────────
    /// @notice Thrown when the caller is the router or otherwise unauthorized.
    error BirdieswapWrapperV1__UnauthorizedAccess();

    // ──────────────────────── Validation ─────────────────────────
    /// @notice Thrown when a zero address is supplied where not allowed.
    error BirdieswapWrapperV1__ZeroAddressNotAllowed();
    /// @notice Thrown when a zero amount is supplied where not allowed.
    error BirdieswapWrapperV1__ZeroAmountNotAllowed();
    /// @notice Thrown when a linked external contract (e.g., EventRelayer) is unrecognized or invalid.
    error BirdieswapWrapperV1__UnrecognizedContract();

    // ──────────────────────── Token Logic ────────────────────────
    /// @notice Thrown when neither leg of a dual vault pair contains WETH.
    error BirdieswapWrapperV1__NoWETHInPair();
    /// @notice Thrown when WETH is incorrectly treated as native ETH input.
    error BirdieswapWrapperV1__WETHIsNotNativeEthereum();
    /// @notice Thrown when a non-WETH token is used where only WETH is accepted.
    error BirdieswapWrapperV1__OnlyWETHIsAccepted();
    /// @notice Thrown when a swap tries to output WETH instead of unwrapped ETH.
    error BirdieswapWrapperV1__WETHAsOutputNotSupported();
    /// @notice Thrown when a swap attempts to use WETH as input where ETH is expected.
    error BirdieswapWrapperV1__WETHIsNotAcceptedAsInput();

    // ──────────────────────── Flow Control ───────────────────────
    /// @notice Thrown when the wrapper does not receive expected tokens from router.
    error BirdieswapWrapperV1__WrapperDidNotReceiveTokens();
    /// @notice Thrown when router refund on ETH exceeds the amount originally sent.
    error BirdieswapWrapperV1__UnexpectedETHRefund();
    /// @notice Thrown when router refund on ERC20 exceeds the amount originally sent.
    error BirdieswapWrapperV1__UnexpectedTokenRefund();
    /// @notice Thrown when direct ETH transfers (non-WETH) are received.
    error BirdieswapWrapperV1__DirectETHTransferNotSupported();

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── Version ──────────────────────────
    /// @notice Contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapWrapperV1";

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Core Contracts ───────────────────────
    /// @notice Immutable pointer to the trusted Birdieswap Router contract.
    IBirdieswapRouterV1 private immutable i_router;

    /// @notice Immutable canonical WETH9 contract instance (chain-specific).
    IWETH9 private immutable i_weth;

    /// @notice Immutable pointer to the centralized event relayer.
    IBirdieswapEventRelayerV1 private immutable i_event;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes immutable contract references and performs one-time router allowance setup for canonical WETH.
     * @dev    - Fetches the canonical WETH address from BirdieswapConfigV1.
     *         - Validates all constructor inputs (no zero address allowed).
     *         - Confirms the router and event relayer contracts are recognized.
     *         - Grants the router an infinite WETH allowance for lifetime use.
     *
     * @param configAddress_   The BirdieswapConfigV1 contract address.
     * @param router_          The trusted BirdieswapRouterV1 contract address.
     * @param eventRelayer_    The BirdieswapEventRelayerV1 contract address.
     *
     * @custom:security
     *         - The constructor sets all immutable dependencies.
     *         - Once deployed, the wrapper is permissionless and non-upgradeable.
     *         - Router trust assumptions are enforced via governance timelocks.
     */
    constructor(address configAddress_, address router_, address eventRelayer_) {
        // ──────────────────── Validate inputs ────────────────────
        if (configAddress_ == address(0) || router_ == address(0) || eventRelayer_ == address(0)) {
            revert BirdieswapWrapperV1__ZeroAddressNotAllowed();
        }

        // ───────────────── Canonical References ──────────────────
        BirdieswapConfigV1 config = BirdieswapConfigV1(configAddress_);
        address weth_ = config.i_weth();
        if (weth_ == address(0)) revert BirdieswapWrapperV1__ZeroAddressNotAllowed();

        i_router = IBirdieswapRouterV1(router_);
        i_weth = IWETH9(weth_);
        i_event = IBirdieswapEventRelayerV1(eventRelayer_);

        // ───────────────────── Sanity Checks ─────────────────────
        // Ensure router recognizes the canonical WETH as a listed token.
        if (i_router.getBTokenAddress(address(i_weth)) == address(0)) revert BirdieswapWrapperV1__ZeroAddressNotAllowed();

        // Verify event relayer version for deployment consistency.
        if (keccak256(bytes(i_event.getVersion())) != keccak256(bytes("BirdieswapEventRelayerV1"))) {
            revert BirdieswapWrapperV1__UnrecognizedContract();
        }

        // ──────────────────── Allowance Setup ────────────────────
        // Router receives a one-time, infinite WETH allowance.
        // WETH9 is immutable and audited, making this safe.
        i_weth.forceApprove(router_, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS                  
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── View Getters ────────────────────────
    /// @notice Returns the contract version identifier.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /**
     * @notice Returns the trusted BirdieswapRouterV1 address.
     * @dev Primarily for UI verification and off-chain integrity checks.
     */
    function getRouterAddress() external view returns (address) {
        return address(i_router);
    }

    /**
     * @notice Returns the canonical WETH9 address used by this deployment.
     * @dev Useful for chain-specific integration checks.
     */
    function getWETHAddress() external view returns (address) {
        return address(i_weth);
    }

    // ───────────────────────── Modifiers ─────────────────────────
    /**
     * @dev Prevents router-initiated calls for additional safety. Ensures the router cannot trigger any wrapper function,
     *      preserving CEI (Checks–Effects–Interactions) guarantees.
     */
    modifier onlyNonRouter() {
        if (msg.sender == address(i_router)) revert BirdieswapWrapperV1__UnauthorizedAccess();
        _;
    }

    // ─────────────────────── Single Vault ────────────────────────
    // Handles ETH <-> single-asset vault interactions through the Router.
    /**
     * @notice Deposits native ETH into a single-asset vault via the router.
     * @dev    - Wraps ETH → WETH.
     *         - Delegates to router for minting bTokens.
     *         - Transfers minted bTokens to the caller.
     *
     * Emits {SingleDepositETH}.
     */
    function singleDepositWithETH() external payable nonReentrant onlyNonRouter returns (uint256) {
        uint256 ethAmount = msg.value;
        if (ethAmount == 0) revert BirdieswapWrapperV1__ZeroAmountNotAllowed();

        // Wrap ETH → WETH (WETH contract is trusted; no callback risk)
        i_weth.deposit{ value: ethAmount }();

        // Call router to handle WETH deposit (router is pre-approved to transferFrom wrapper)
        address wethAddress = address(i_weth);
        uint256 minted = i_router.singleDeposit(wethAddress, ethAmount);

        // Send minted bTokens to user
        address bTokenAddress = i_router.getBTokenAddress(wethAddress);
        if (minted > 0 && bTokenAddress != address(0)) IERC20(bTokenAddress).safeTransfer(msg.sender, minted);
        else revert BirdieswapWrapperV1__WrapperDidNotReceiveTokens();

        try i_event.emitSingleDepositETH(msg.sender, ethAmount, minted) { } catch { }

        return minted;
    }

    /**
     * @notice Redeems a single-asset vault position back to native ETH.
     * @dev    - Transfers user’s bTokens into the wrapper.
     *         - Redeems via router (bToken → WETH).
     *         - Unwraps WETH → ETH and returns it to user.
     *
     * Emits {SingleRedeemETH}.
     */
    function singleRedeemToETH(address _bTokenAddress, uint256 _bTokenAmount) external nonReentrant onlyNonRouter returns (uint256) {
        if (i_router.getUnderlyingTokenAddress(_bTokenAddress) != address(i_weth)) revert BirdieswapWrapperV1__OnlyWETHIsAccepted();
        if (_bTokenAmount == 0) revert BirdieswapWrapperV1__ZeroAmountNotAllowed();

        // Pull bTokens from user into wrapper
        IERC20(_bTokenAddress).safeTransferFrom(msg.sender, address(this), _bTokenAmount);

        // Approve router to pull bTokens from wrapper if needed
        _ensureRouterAllowance(IERC20(_bTokenAddress), _bTokenAmount);

        // Redeem bToken → WETH via router
        uint256 wethAmount = i_router.singleRedeem(_bTokenAddress, _bTokenAmount);

        // Unwrap WETH → ETH and send to user (safe due to nonReentrant guard)
        i_weth.withdraw(wethAmount);
        payable(msg.sender).sendValue(wethAmount);

        try i_event.emitSingleRedeemETH(msg.sender, _bTokenAddress, wethAmount) { } catch { }

        return wethAmount;
    }

    // ──────────────────────── Dual Vault ─────────────────────────
    // Handles ETH + ERC20 dual-asset deposits and redemptions.
    /**
     * @notice Deposits ETH and another ERC20 token into a dual vault.
     * @dev    - Wraps ETH once.
     *         - Transfers the secondary token.
     *         - Executes router deposit and handles refunds safely.
     *
     * Emits {DualDepositWithETH}.
     *
     * @dev Assumes the router's dualDeposit() and dualRedeem() return refund amounts ordered by (token0, token1) in the same way as
     *      getBTokenPair(blpToken). This wrapper does not infer ordering from token addresses.
     */
    function dualDepositWithETH(address _underlyingTokenAddress, uint256 _underlyingTokenAmount)
        external
        payable
        nonReentrant
        onlyNonRouter
        returns (uint256, uint256, uint256)
    {
        uint256 ethAmount = msg.value;
        if (ethAmount == 0 || _underlyingTokenAmount == 0) revert BirdieswapWrapperV1__ZeroAmountNotAllowed();
        if (_underlyingTokenAddress == address(0)) revert BirdieswapWrapperV1__ZeroAddressNotAllowed();
        if (_underlyingTokenAddress == address(i_weth)) revert BirdieswapWrapperV1__WETHIsNotNativeEthereum();
        IBirdieswapRouterV1 router = i_router;

        // Wrap ETH once; WETH is then used by router.
        i_weth.deposit{ value: ethAmount }();

        // Pull other token and approve router if needed.
        IERC20(_underlyingTokenAddress).safeTransferFrom(msg.sender, address(this), _underlyingTokenAmount);
        _ensureRouterAllowance(IERC20(_underlyingTokenAddress), _underlyingTokenAmount);

        // Execute dual deposit via router.
        // Router returns both minted blpToken and underlying token refunds (already converted from leftover bTokens).
        (uint256 blpTokenAmount, uint256 underlyingToken0AmountReturned, uint256 underlyingToken1AmountReturned) =
            router.dualDeposit(msg.sender, address(i_weth), ethAmount, _underlyingTokenAddress, _underlyingTokenAmount);

        // Forward refunds back to user. Refund legs map strictly by bToken address order.
        // Refund handling: ensures router-returned values do not exceed deposits.
        if (router.isBToken0First(router.getBTokenAddress(address(i_weth)), router.getBTokenAddress(_underlyingTokenAddress))) {
            // Case 1: underlyingToken of bToken0 is WETH, underlyingToken of bToken1 is other token
            if (underlyingToken0AmountReturned > ethAmount) revert BirdieswapWrapperV1__UnexpectedETHRefund();
            if (underlyingToken1AmountReturned > _underlyingTokenAmount) revert BirdieswapWrapperV1__UnexpectedTokenRefund();

            if (underlyingToken0AmountReturned > 0) {
                i_weth.withdraw(underlyingToken0AmountReturned);
                payable(msg.sender).sendValue(underlyingToken0AmountReturned);
            }
            if (underlyingToken1AmountReturned > 0) {
                IERC20(_underlyingTokenAddress).safeTransfer(msg.sender, underlyingToken1AmountReturned);
            }

            // The event logs net ETH and token amounts after refunds,
            // allowing accurate off-chain tracking of effective contributions.
            try i_event.emitDualDepositWithETH(
                msg.sender,
                ethAmount - underlyingToken0AmountReturned,
                _underlyingTokenAddress,
                _underlyingTokenAmount - underlyingToken1AmountReturned,
                blpTokenAmount
            ) { } catch { }
        } else {
            // Case 2: underlyingToken of bToken0 is other token, underlyingToken of bToken1 is WETH
            if (underlyingToken0AmountReturned > _underlyingTokenAmount) revert BirdieswapWrapperV1__UnexpectedTokenRefund();
            if (underlyingToken1AmountReturned > ethAmount) revert BirdieswapWrapperV1__UnexpectedETHRefund();

            if (underlyingToken0AmountReturned > 0) {
                IERC20(_underlyingTokenAddress).safeTransfer(msg.sender, underlyingToken0AmountReturned);
            }
            if (underlyingToken1AmountReturned > 0) {
                i_weth.withdraw(underlyingToken1AmountReturned);
                payable(msg.sender).sendValue(underlyingToken1AmountReturned);
            }

            // The event logs net ETH and token amounts after refunds,
            // allowing accurate off-chain tracking of effective contributions.
            try i_event.emitDualDepositWithETH(
                msg.sender,
                ethAmount - underlyingToken1AmountReturned,
                _underlyingTokenAddress,
                _underlyingTokenAmount - underlyingToken0AmountReturned,
                blpTokenAmount
            ) { } catch { }
        }

        // Send the minted blpToken (Birdieswap dual vault LP token) to the user.
        address blpTokenAddress =
            router.getBLPTokenAddress(router.getBTokenAddress(address(i_weth)), router.getBTokenAddress(_underlyingTokenAddress));
        IERC20(blpTokenAddress).safeTransfer(msg.sender, blpTokenAmount);

        return (blpTokenAmount, underlyingToken0AmountReturned, underlyingToken1AmountReturned);
    }

    /**
     * @notice Redeems a dual vault (blpToken) back to ETH and another token.
     * @dev    - Supports both (WETH, token) and (token, WETH) pair layouts.
     *         - Unwraps WETH to ETH automatically.
     *
     * Emits {DualRedeemToETH}.
     */
    function dualRedeemToETH(address _blpTokenAddress, uint256 _blpTokenAmount)
        external
        nonReentrant
        onlyNonRouter
        returns (uint256, uint256)
    {
        if (_blpTokenAddress == address(0)) revert BirdieswapWrapperV1__ZeroAddressNotAllowed();
        if (_blpTokenAmount == 0) revert BirdieswapWrapperV1__ZeroAmountNotAllowed();

        // Pull blpToken from user into wrapper
        IERC20(_blpTokenAddress).safeTransferFrom(msg.sender, address(this), _blpTokenAmount);

        // Approve router to pull blpToken if needed
        _ensureRouterAllowance(IERC20(_blpTokenAddress), _blpTokenAmount);

        // Get bToken pair and their underlying assets
        (address bToken0Address, address bToken1Address) = i_router.getBTokenPair(_blpTokenAddress);
        address token0Address = i_router.getUnderlyingTokenAddress(bToken0Address);
        address token1Address = i_router.getUnderlyingTokenAddress(bToken1Address);

        // Redeem blpToken → bTokens via router
        (uint256 token0Amount, uint256 token1Amount) = i_router.dualRedeem(msg.sender, _blpTokenAddress, _blpTokenAmount);

        // If one side is WETH, unwrap and forward ETH; forward the other ERC20 as-is.
        address wethAddress = address(i_weth);
        if (token0Address == wethAddress) {
            if (token0Amount > 0) {
                i_weth.withdraw(token0Amount);
                payable(msg.sender).sendValue(token0Amount);
            }
            if (token1Amount > 0 && token1Address != address(0)) IERC20(token1Address).safeTransfer(msg.sender, token1Amount);
        } else if (token1Address == wethAddress) {
            if (token1Amount > 0) {
                i_weth.withdraw(token1Amount);
                payable(msg.sender).sendValue(token1Amount);
            }
            if (token0Amount > 0 && token0Address != address(0)) IERC20(token0Address).safeTransfer(msg.sender, token0Amount);
        } else {
            revert BirdieswapWrapperV1__NoWETHInPair();
        } // Sanity check: both legs cannot be non-WETH by design.

        try i_event.emitDualRedeemToETH(msg.sender, _blpTokenAddress, token0Address, token0Amount, token1Address, token1Amount) { }
            catch { }

        return (token0Amount, token1Amount);
    }

    // ─────────────────────────── Swaps ───────────────────────────
    /**
     * @notice Swaps native ETH for an ERC20 via the router.
     * @dev    Wraps ETH → WETH, swaps through router, and transfers output tokens.
     *
     * Emits {SwapFromETH}.
     */
    function swapFromETH(uint24 _feeTier, address _tokenOut, uint256 _minAmountOut, uint160 _sqrtPriceLimitX96, address _referrerAddress)
        external
        payable
        nonReentrant
        onlyNonRouter
        returns (uint256)
    {
        uint256 amountIn = msg.value;
        if (amountIn == 0) revert BirdieswapWrapperV1__ZeroAmountNotAllowed();
        if (_tokenOut == address(0)) revert BirdieswapWrapperV1__ZeroAddressNotAllowed();
        address wethAddress = address(i_weth);
        if (_tokenOut == wethAddress) revert BirdieswapWrapperV1__WETHAsOutputNotSupported();

        // Wrap ETH
        i_weth.deposit{ value: amountIn }();

        // Swap via router (router is pre-approved for WETH)
        uint256 amountOut = i_router.swap(wethAddress, _feeTier, _tokenOut, amountIn, _minAmountOut, _sqrtPriceLimitX96, _referrerAddress);

        IERC20(_tokenOut).safeTransfer(msg.sender, amountOut);

        try i_event.emitSwapFromETH(msg.sender, amountIn, _tokenOut, amountOut) { } catch { }

        return amountOut;
    }

    /**
     * @notice Swaps an ERC20 token for native ETH via the router.
     * @dev    Transfers `tokenIn` from the user, approves router, swaps to WETH, unwraps to ETH, and returns it safely.
     *
     * Emits {SwapToETH}.
     */
    function swapToETH(
        address _tokenIn,
        uint24 _feeTier,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint160 _sqrtPriceLimitX96,
        address _referrerAddress
    ) external nonReentrant onlyNonRouter returns (uint256) {
        if (_amountIn == 0) revert BirdieswapWrapperV1__ZeroAmountNotAllowed();
        if (_tokenIn == address(0)) revert BirdieswapWrapperV1__ZeroAddressNotAllowed();
        address wethAddress = address(i_weth);
        if (_tokenIn == wethAddress) revert BirdieswapWrapperV1__WETHIsNotAcceptedAsInput();

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        // Approve tokenIn for router if needed
        _ensureRouterAllowance(IERC20(_tokenIn), _amountIn);

        uint256 wethAmount = i_router.swap(_tokenIn, _feeTier, wethAddress, _amountIn, _minAmountOut, _sqrtPriceLimitX96, _referrerAddress);

        // Unwrap WETH to native ETH
        i_weth.withdraw(wethAmount);
        payable(msg.sender).sendValue(wethAmount);

        try i_event.emitSwapToETH(msg.sender, _tokenIn, _amountIn, wethAmount) { } catch { }

        return wethAmount;
    }

    // ─────────────────────── ETH Handling ────────────────────────
    /**
     * @notice Receives ETH only from WETH withdrawals.
     * @dev Reverts on any non-WETH ETH transfer to prevent malicious or accidental deposits.
     *      However, forced ETH can still be sent via SELFDESTRUCT (and certain edge VM behaviors).
     *      So, the contract will never base critical logic on address(this).balance.
     */
    receive() external payable {
        if (msg.sender != address(i_weth)) revert BirdieswapWrapperV1__DirectETHTransferNotSupported();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL UTILITIES
        Minimal internal helpers used for router interactions.
        Contains no external-state modifications beyond approvals.
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Ensures router has sufficient allowance for `_token`.
     *      Resets to infinite allowance if current is insufficient.
     */
    function _ensureRouterAllowance(IERC20 _token, uint256 _amount) internal {
        if (_token.allowance(address(this), address(i_router)) < _amount) {
            _token.forceApprove(address(i_router), type(uint256).max);
        }
    }
}
/*//////////////////////////////////////////////////////////////
                        END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant Router never performs callbacks or external calls into Wrapper.
/// @custom:invariant All mutative functions are `nonReentrant` and follow CEI (Checks–Effects–Interactions).
/// @custom:invariant Wrapper holds no user funds between transactions; all assets are forwarded atomically.
/// @custom:invariant Only canonical WETH may send ETH to Wrapper; direct ETH transfers revert.
/// @custom:invariant Wrapper is immutable and permissionless — no owner, governance, or upgrade hooks.
/// @custom:invariant Refund and mint amounts returned by Router never exceed inputs.
/// @custom:invariant Token-pair ordering validated via `router.isBToken0First()`, never inferred by address order.
