// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { ERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC4626 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { Pausable } from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "./BirdieswapConfigV1.sol";
import { BirdieswapRoleSignaturesV1 } from "./BirdieswapRoleSignaturesV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapRoleRouterV1 } from "./interfaces/IBirdieswapRoleRouterV1.sol";
import { IBirdieswapSingleStrategyV1 } from "./interfaces/IBirdieswapSingleStrategyV1.sol";

/*//////////////////////////////////////////////////////////////
                              CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapSingleVaultV1
 * @author Birdieswap Team
 * @notice ERC4626-compliant vault wrapping a SingleStrategyV1 to provide composable yield exposure on a vanilla underlying token.
 *
 * @dev ─────────────────────── Architecture ───────────────────────
 *      Router → Vault → Strategy → Pool
 *      - Accepts deposits in underlying, forwards to an ERC4626-compatible strategy.
 *      - Mints Birdieswap bTokens (wrapped proof tokens) as user shares.
 *      - All modules except Router are immutable and deployed by governance.
 *
 * @dev ────────────────────────── Assets ──────────────────────────
 *      In Birdieswap’s dual-layer design:
 *        - `asset()`              → strategy’s ERC4626 proof token (Layer-2 asset)
 *        - `underlyingToken()`    → ultimate redeemable vanilla token (Layer-1 asset)
 *        - Birdieswap bTokens     → vault shares representing proof-token ownership
 *
 * @dev ────────────────────────── Roles ───────────────────────────
 *      - Admin       : manages role assignments and high-level config.
 *      - Timelock    : authorizes delayed strategy activation.
 *      - Manager     : triggers upkeep (hard work, emergency exit).
 *      - Guardian    : may pause deposits/mints (withdraws always open).
 *
 * @dev ─────────────────────── Trust Model ────────────────────────
 *      Strategy and Router are fully governed, verified, and non-upgradeable.
 *      Vault never interacts with untrusted third-party contracts.
 *
 * @dev ────────────────── Deployment & Bootstrap ──────────────────
 *      1. Vault is deployed first (s_strategyAddress == 0).
 *      2. Strategy deploys referencing this vault.
 *      3. Governance proposes and later accepts it via timelock (two-step).
 *
 * @dev ───────────────────── Bootstrap Design ─────────────────────
 *      - `s_strategyAddress` may be zero only until {acceptStrategy()} executes.
 *      - No `whenStrategySet` modifier on hot paths (gas-optimized).
 *      - Pre-activation calls to deposit/mint/withdraw/redeem revert via call to
 *        address(0) — intentional design to gate actions until activation.
 *      - Once activated, strategy address remains nonzero for vault lifetime.
 *
 * @dev ───────────────────────── Summary ──────────────────────────
 *      This contract forms the ERC4626 “vault layer” above SingleStrategyV1.
 *      It standardizes capital flow, maintains invariant tolerance checks,
 *      and guarantees safe exits even under paused conditions.
 */
contract BirdieswapSingleVaultV1 is ERC4626, ERC20Permit, ReentrancyGuard, Pausable, BirdieswapRoleSignaturesV1 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── Validation & Math ─────────────────────
    error BirdieswapSingleVaultV1__InvalidAmount();
    error BirdieswapSingleVaultV1__ConversionOutOfTolerance();
    error BirdieswapSingleVaultV1__UnderlyingDeltaOutOfTolerance();
    error BirdieswapSingleVaultV1__StrategyReturnedZero();
    error BirdieswapSingleVaultV1__InvalidStrategy();
    error BirdieswapSingleVaultV1__ZeroAddressNotAllowed();

    // ──────────────────────── Access Control ─────────────────────
    error BirdieswapSingleVaultV1__UnauthorizedAccess();

    // ───────────────────── Governance / Rescue ───────────────────
    error BirdieswapSingleVaultV1__CannotRescueBToken();
    error BirdieswapSingleVaultV1__CannotRescueProofToken();
    error BirdieswapSingleVaultV1__CannotRescueUnderlyingToken();
    error BirdieswapSingleVaultV1__InvalidEmergencyExitReturn();

    /*//////////////////////////////////////////////////////////////
                                  ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reasons for strategy validation failure during propose/accept workflow.
    enum SingleStrategyValidationReason {
        ZERO_ADDRESS, // 0
        SAME_AS_EXISTING, // 1
        NOT_CONTRACT, // 2
        VAULT_MISMATCH, // 3
        UNDERLYING_MISMATCH, // 4
        PROOF_TOKEN_MISMATCH, // 5
        DEPOSIT_PREVIEW_FAIL, // 6
        WITHDRAW_PREVIEW_FAIL, // 7
        MATH_INCONSISTENT // 8

    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version identifier (used for on-chain introspection and audits).
    string private constant CONTRACT_VERSION = "BirdieswapSingleVaultV1";

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Dependencies ────────────────────────
    IBirdieswapRoleRouterV1 private immutable i_role;
    IBirdieswapEventRelayerV1 private immutable i_event;

    // ────────────────────────── Tokens ───────────────────────────
    /**
     * @dev Immutable token references (set once at construction):
     *      - `i_underlyingTokenAddress` : ultimate vanilla ERC20 the vault redeems to.
     *      - `i_proofTokenAddress`      : ERC4626-compatible proof token from the strategy’s pool.
     *
     * Transfer-fee / rebasing tokens are unsupported — only standard ERC20s with 1:1 semantics are listed within Birdieswap.
     * These are pre-screened at listing; no runtime checks are performed for gas efficiency.
     */
    address private immutable i_underlyingTokenAddress;
    address private immutable i_proofTokenAddress;

    // ──────────────────────── Tolerances ─────────────────────────
    /// @notice Conversion deviation thresholds for ERC4626 ↔ strategy math reconciliation.
    /// @dev Absolute tolerance: up to 2 wei. Relative tolerance: up to 1 basis point (0.01%).
    uint256 private immutable i_absoluteToleranceInWei;
    uint256 private immutable i_relativeToleranceInBp;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ──────────────────────── Strategies ─────────────────────────
    /**
     * @dev The active strategy this vault delegates capital to.
     *      May remain temporarily unset (== address(0)) during initial deployment.
     *
     * Bootstrap lifecycle:
     *   1. Vault is deployed (no strategy set).
     *   2. Strategy is deployed referencing this vault.
     *   3. VaultManager proposes it via {proposeStrategy()}.
     *   4. Timelock activates via {acceptStrategy()}.
     *
     * During this bootstrap period, functions depending on `s_strategyAddress` are not expected to be called.
     * Once accepted, the strategy address remains nonzero and valid for the vault’s lifetime.
     *
     * NOTE: Per-call “whenStrategySet” modifiers are intentionally omitted to avoid lifetime SLOAD overhead.
     *       See “Bootstrap design” in contract header for integrator guidance.
     */
    address private s_strategyAddress;

    /// @notice Pending strategy proposed but not yet accepted.
    address private s_pendingStrategyAddress;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @param configAddress_        Address of immutable BirdieswapConfig (provides tolerance and shared params).
     * @param underlyingToken_      Ultimate vanilla ERC20 the vault redeems to.
     * @param proofToken_           ERC4626-compatible proof token from the strategy’s pool.
     * @param name_                 ERC20 name for this vault’s bToken.
     * @param symbol_               ERC20 symbol for this vault’s bToken.
     * @param roleRouterAddress_    Centralized BirdieswapRoleRouterV1 address.
     * @param eventRelayerAddress_  BirdieswapEventRelayerV1 address.
     */
    constructor(
        address configAddress_,
        address underlyingToken_,
        address proofToken_,
        string memory name_,
        string memory symbol_,
        address roleRouterAddress_,
        address eventRelayerAddress_
    ) ERC20(name_, symbol_) ERC4626(ERC20(proofToken_)) ERC20Permit(name_) {
        // ───────────────── Config / Dependencies ─────────────────
        if (configAddress_ == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();
        BirdieswapConfigV1 config = BirdieswapConfigV1(configAddress_);

        if (roleRouterAddress_ == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();
        i_role = IBirdieswapRoleRouterV1(roleRouterAddress_);

        if (eventRelayerAddress_ == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();
        i_event = IBirdieswapEventRelayerV1(eventRelayerAddress_);

        // ────────────────────── Token setup ──────────────────────
        if (underlyingToken_ == address(0) || proofToken_ == address(0)) {
            revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();
        }

        i_underlyingTokenAddress = underlyingToken_;
        i_proofTokenAddress = proofToken_;

        // ─────────────────── Config parameters ───────────────────
        i_absoluteToleranceInWei = config.i_absoluteToleranceInWei();
        i_relativeToleranceInBp = config.i_relativeToleranceInBp();

        // Strategy address left unset; governance must activate via propose/accept flow
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────────── Metadata ─────────────────────────
    /// @notice Returns the contract version identifier.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /// @notice Returns the number of decimals used to represent token amounts.
    /// @dev Uses the ERC4626-decimals (matches the proof token’s decimals).
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    // ───────────────────────── Modifiers ─────────────────────────
    /// @dev Restricts access from the active strategy contract itself.
    modifier onlyNonStrategy() {
        if (_msgSender() == address(s_strategyAddress)) {
            revert BirdieswapSingleVaultV1__UnauthorizedAccess();
        }
        _;
    }

    /// @dev Restricts to guardian roles (GUARDIAN_ROLE or GUARDIAN_FULL_ROLE).
    modifier onlyGuardianRole() {
        if (!(i_role.hasRoleGlobal(GUARDIAN_ROLE, _msgSender()) || i_role.hasRoleGlobal(GUARDIAN_FULL_ROLE, _msgSender()))) {
            revert BirdieswapSingleVaultV1__UnauthorizedAccess();
        }
        _;
    }

    /// @dev Restricts to manager role (MANAGER_ROLE).
    modifier onlyManagerRole() {
        if (!i_role.hasRoleGlobal(MANAGER_ROLE, _msgSender())) {
            revert BirdieswapSingleVaultV1__UnauthorizedAccess();
        }
        _;
    }

    /// @dev Restricts to upgrader role (UPGRADER_ROLE).
    modifier onlyUpgraderRole() {
        if (!i_role.hasRoleGlobal(UPGRADER_ROLE, _msgSender())) {
            revert BirdieswapSingleVaultV1__UnauthorizedAccess();
        }
        _;
    }

    // ─────────────────────── Pause Control ───────────────────────
    /// @notice Temporarily halts new deposits/mints; withdrawals remain active.
    /// @dev    Birdieswap design principle: user withdrawals must always remain possible.
    function pause() external onlyGuardianRole {
        _pause();
        try i_event.emitSingleDepositsPaused(_msgSender()) { } catch { }
    }

    /// @notice Resumes deposit and mint operations after a pause.
    function unpause() external onlyGuardianRole {
        _unpause();
        try i_event.emitSingleDepositsUnpaused(_msgSender()) { } catch { }
    }

    // ──────────────────── Strategy Accessors ─────────────────────
    /// @notice Returns the currently active strategy address.
    function getStrategy() external view returns (address) {
        return s_strategyAddress;
    }

    /// @notice Returns the pending (proposed) strategy address.
    function getPendingStrategy() external view returns (address) {
        return s_pendingStrategyAddress;
    }

    /// @notice Returns true once the strategy has been activated at least once.
    /// @dev Purely for integrations; avoids SLOADs on hot paths.
    function isStrategyActive() external view returns (bool) {
        return s_strategyAddress != address(0);
    }

    // ────────────────────── Asset Accessors ──────────────────────
    /**
     * @notice Returns the final redeemable vanilla token of this vault.
     * @dev Birdieswap vaults use a 2layer ERC4626 model:
     *      - `asset()` is the strategy’s proof token (Layer 2 share).
     *      - `underlyingToken()` is the ultimate vanilla asset (Layer 1).
     *      External integrators should use {underlyingToken()} for UI/mapping; internal math uses `asset()`.
     */
    function underlyingToken() external view returns (address) {
        return i_underlyingTokenAddress;
    }

    /// @notice Returns the configured conversion tolerances (absolute and relative).
    function getTolerances() external view returns (uint256, uint256) {
        return (i_absoluteToleranceInWei, i_relativeToleranceInBp);
    }

    /// @notice Returns total proof tokens held by this vault — the vault’s ERC4626 asset().
    function totalAssets() public view override returns (uint256) {
        return IERC20(i_proofTokenAddress).balanceOf(address(this));
    }

    /**
     * @notice Returns the total underlying token balance held in the vault (for analytics only).
     * @dev Values may briefly diverge during in-flight operations; this does not affect accounting.
     */
    function totalUnderlyingBalance() public view returns (uint256) {
        if (s_strategyAddress == address(0)) return IERC20(i_underlyingTokenAddress).balanceOf(address(this));

        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(s_strategyAddress);
        IERC20 proofToken = IERC20(i_proofTokenAddress);
        IERC20 underlying = IERC20(i_underlyingTokenAddress);
        address self = address(this);

        // Total = proof tokens converted to assets + any idle underlying.
        return strategy.convertToAssets(proofToken.balanceOf(self)) + underlying.balanceOf(self);
    }

    /*//////////////////////////////////////////////////////////////
                         ERC4626 PREVIEW EXTENSIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @custom:bootstrap Requires an active strategy. Calling before {acceptStrategy()} reverts
     *                   via external call to address(0). Integrators must wait for {StrategyAccepted}
     *                   or check {getStrategy()!=address(0)}.
     */
    // ────────────────────────── Preview (2-layer) ──────────────────────────
    /// @notice Previews resulting bTokens from depositing given underlying (vault  strategy layers).
    function previewFullDeposit(uint256 _underlyingTokenAmount) public view returns (uint256) {
        if (s_strategyAddress == address(0)) revert BirdieswapSingleVaultV1__InvalidStrategy();
        uint256 proofAmount = IBirdieswapSingleStrategyV1(s_strategyAddress).previewDeposit(_underlyingTokenAmount);
        return previewDeposit(proofAmount);
    }

    /// @notice Returns required underlying token amount to mint a given bToken amount (2-layer preview).
    function previewFullMint(uint256 _bTokenAmount) public view returns (uint256) {
        if (s_strategyAddress == address(0)) revert BirdieswapSingleVaultV1__InvalidStrategy();
        uint256 proofAmount = previewMint(_bTokenAmount);
        return IBirdieswapSingleStrategyV1(s_strategyAddress).previewMint(proofAmount);
    }

    /// @notice Returns underlying tokens received when redeeming given bTokens (2-layer preview).
    function previewFullRedeem(uint256 _bTokenAmount) public view returns (uint256) {
        if (s_strategyAddress == address(0)) revert BirdieswapSingleVaultV1__InvalidStrategy();
        uint256 proofAmount = previewRedeem(_bTokenAmount);
        return IBirdieswapSingleStrategyV1(s_strategyAddress).previewRedeem(proofAmount);
    }

    /// @notice Returns bToken amount required to withdraw given underlying token amount (2-layer preview).
    function previewFullWithdraw(uint256 _underlyingTokenAmount) public view returns (uint256) {
        if (s_strategyAddress == address(0)) revert BirdieswapSingleVaultV1__InvalidStrategy();
        uint256 proofAmount = IBirdieswapSingleStrategyV1(s_strategyAddress).previewWithdraw(_underlyingTokenAmount);
        return previewWithdraw(proofAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           USER-FACING OPERATIONS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── DEPOSIT ──────────────────────────
    /**
     * @notice Deposits vanilla underlying tokens into the Birdieswap vault.
     * @dev Performs a full 2-layer ERC4626 deposit:
     *      1. User (or Router) transfers underlying to this vault.
     *      2. Vault forwards underlying to the strategy.
     *      3. Strategy deposits into its protocol and returns proof tokens.
     *      4. Vault mints Birdieswap bTokens (wrapped proof tokens) to the receiver.
     *
     * - Preview checks ensure proof-token and bToken mints remain within tolerance.
     * - Callable only when not paused; guarded by `nonReentrant` and `onlyNonStrategy`.
     *
     * @param _underlyingTokenAmount Amount of vanilla tokens to deposit.
     * @param _receiverAddress       Recipient of minted Birdieswap bTokens.
     * @return bTokenAmount          Amount of bTokens minted to the receiver.
     *
     * Emits {SingleDeposit}.
     * @custom:bootstrap Requires active strategy; calling before {acceptStrategy()} reverts.
     */
    function deposit(uint256 _underlyingTokenAmount, address _receiverAddress)
        public
        override
        nonReentrant
        whenNotPaused
        onlyNonStrategy
        returns (uint256)
    {
        if (_underlyingTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();
        if (_receiverAddress == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();

        address strategyAddress = s_strategyAddress;
        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(strategyAddress);
        IERC20 proof = IERC20(i_proofTokenAddress);

        // ────────────────── PREVIEW VALIDATION ───────────────────
        uint256 estimatedProofTokenAmount = strategy.previewDeposit(_underlyingTokenAmount);
        uint256 estimatedBTokenAmount = previewDeposit(estimatedProofTokenAmount);
        if (estimatedProofTokenAmount == 0 || estimatedBTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();

        // ────────────────────── TOKEN FLOW ───────────────────────
        {
            IERC20 underlying = IERC20(i_underlyingTokenAddress);
            address msgSender = _msgSender();
            _underlyingTokenAmount = _validateTokenAmount(msgSender, i_underlyingTokenAddress, _underlyingTokenAmount);

            // Pull and forward vanilla token to strategy
            underlying.safeTransferFrom(msgSender, address(this), _underlyingTokenAmount);
            underlying.safeTransfer(strategyAddress, _underlyingTokenAmount);
        }

        // ───────────────────── STRATEGY CALL ─────────────────────
        uint256 supplyBefore = totalSupply();
        uint256 proofBefore = proof.balanceOf(address(this));
        uint256 proofTokenAmount = strategy.deposit(_underlyingTokenAmount);
        if (!_isWithinTolerance(estimatedProofTokenAmount, proofTokenAmount)) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
        if (proofTokenAmount == 0) revert BirdieswapSingleVaultV1__StrategyReturnedZero();

        // ────────────────── TOLERANCE VERIFICATION ───────────────
        if (proofBefore == 0 && supplyBefore != 0 || supplyBefore == 0 && proofBefore != 0) {
            revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
        }
        uint256 sharesCalculated = (supplyBefore == 0) ? proofTokenAmount : Math.mulDiv(proofTokenAmount, supplyBefore, proofBefore);

        if (!_isWithinTolerance(estimatedBTokenAmount, sharesCalculated)) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();

        // ───────────────────── MINT WRAPPER ──────────────────────
        _mint(_receiverAddress, sharesCalculated);
        try i_event.emitSingleDeposit(_receiverAddress, i_underlyingTokenAddress, _underlyingTokenAmount, address(this), sharesCalculated) {
        } catch { }

        return sharesCalculated;
    }

    // ─────────────────────────── MINT ────────────────────────────
    /**
     * @notice Mints a fixed amount of bTokens in exchange for vanilla underlying tokens.
     * @dev Implements ERC4626 `mint()` semantics:
     *      1. Computes required proof tokens and underlying.
     *      2. Pulls underlying from caller, forwards to strategy.
     *      3. Mints exactly `_bTokenAmount` of bTokens to receiver.
     *
     * - Validates all conversions within tolerance.
     * - Callable only when not paused; guarded by `nonReentrant` and `onlyNonStrategy`.
     *
     * @param _bTokenAmount    Desired bToken amount.
     * @param _receiverAddress Recipient of minted bTokens.
     * @return actualUnderlyingTokenAmount  Actual underlying spent.
     *
     * Emits {SingleDeposit}.
     * @custom:bootstrap Requires active strategy; calling before {acceptStrategy()} reverts.
     */
    function mint(uint256 _bTokenAmount, address _receiverAddress)
        public
        override
        nonReentrant
        whenNotPaused
        onlyNonStrategy
        returns (uint256)
    {
        if (_bTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();
        if (_receiverAddress == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();

        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(s_strategyAddress);
        IERC20 underlying = IERC20(i_underlyingTokenAddress);
        IERC20 proof = IERC20(i_proofTokenAddress);

        // ────────────────── PREVIEW VALIDATION ───────────────────
        uint256 estimatedProofTokenAmount = previewMint(_bTokenAmount);
        uint256 estimatedUnderlyingTokenAmount = strategy.previewMint(estimatedProofTokenAmount);
        if (estimatedProofTokenAmount == 0 || estimatedUnderlyingTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();

        // ────────────────────── TOKEN FLOW ───────────────────────
        {
            address msgSender = _msgSender();
            address strategyAddress = address(strategy);
            estimatedUnderlyingTokenAmount = _validateTokenAmount(msgSender, i_underlyingTokenAddress, estimatedUnderlyingTokenAmount);
            underlying.safeTransferFrom(msgSender, address(this), estimatedUnderlyingTokenAmount);
            underlying.safeTransfer(strategyAddress, estimatedUnderlyingTokenAmount);
        }

        // ───────────────────── STRATEGY CALL ─────────────────────
        uint256 proofBefore = proof.balanceOf(address(this));
        uint256 actualUnderlyingTokenAmount = strategy.mint(estimatedProofTokenAmount);
        {
            if (actualUnderlyingTokenAmount == 0) revert BirdieswapSingleVaultV1__StrategyReturnedZero();
            if (!_isWithinTolerance(estimatedUnderlyingTokenAmount, actualUnderlyingTokenAmount)) {
                revert BirdieswapSingleVaultV1__UnderlyingDeltaOutOfTolerance();
            }

            uint256 recheckedProofTokenAmount = strategy.convertToShares(actualUnderlyingTokenAmount);
            if (!_isWithinTolerance(estimatedProofTokenAmount, recheckedProofTokenAmount)) {
                revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
            }

            uint256 proofAfter = proof.balanceOf(address(this));
            if (proofAfter < proofBefore) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
            uint256 delta = proofAfter - proofBefore;
            if (!_isWithinTolerance(estimatedProofTokenAmount, delta)) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
        }

        // ───────────────────── MINT WRAPPER ──────────────────────
        _mint(_receiverAddress, _bTokenAmount);
        try i_event.emitSingleDeposit(_receiverAddress, i_underlyingTokenAddress, actualUnderlyingTokenAmount, address(this), _bTokenAmount)
        { } catch { }
        return actualUnderlyingTokenAmount;
    }

    // ───────────────────────── WITHDRAW ──────────────────────────
    /**
     * @notice Withdraws a fixed amount of vanilla underlying by burning necessary bTokens.
     * @dev ERC4626 `withdraw()` (PULL model):
     *      1. Computes required proof and bTokens.
     *      2. Burns bTokens from owner.
     *      3. Sends proof to strategy and triggers withdrawal.
     *      4. Pushes underlying to receiver.
     *
     * - Tolerance-checked accounting; callable even when paused.
     * - Non-reentrant and `onlyNonStrategy` protected.
     *
     * @return estimatedBTokenAmount Amount of bTokens burned.
     * Emits {SingleWithdraw}.
     */
    function withdraw(uint256 _underlyingTokenAmount, address _receiverAddress, address _ownerAddress)
        public
        override
        nonReentrant
        onlyNonStrategy
        returns (uint256)
    {
        if (_underlyingTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();
        if (_receiverAddress == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();

        address strategyAddress = s_strategyAddress;
        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(strategyAddress);
        IERC20 underlying = IERC20(i_underlyingTokenAddress);
        IERC20 proofToken = IERC20(i_proofTokenAddress);

        // ────────────────── PREVIEW VALIDATION ───────────────────
        uint256 estimatedProofTokenAmount = strategy.previewWithdraw(_underlyingTokenAmount);
        uint256 estimatedBTokenAmount = previewWithdraw(estimatedProofTokenAmount);
        if (estimatedProofTokenAmount == 0 || estimatedBTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();

        // ────────────────────── TOKEN FLOW ───────────────────────
        {
            address msgSender = _msgSender();
            if (msgSender != _ownerAddress) _spendAllowance(_ownerAddress, msgSender, estimatedBTokenAmount);
        }
        _burn(_ownerAddress, estimatedBTokenAmount);

        // ────────────────── STRATEGY REDEMPTION ──────────────────
        proofToken.safeTransfer(strategyAddress, estimatedProofTokenAmount);

        {
            uint256 actualProofTokenUsed = strategy.withdraw(_underlyingTokenAmount);
            if (actualProofTokenUsed == 0) revert BirdieswapSingleVaultV1__StrategyReturnedZero();
            if (!_isWithinTolerance(estimatedProofTokenAmount, actualProofTokenUsed)) {
                revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
            }
            if (actualProofTokenUsed > estimatedProofTokenAmount) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
        }
        // ────────────────── UNDERLYING DELIVERY ──────────────────
        underlying.safeTransfer(_receiverAddress, _underlyingTokenAmount);
        try i_event.emitSingleWithdraw(
            _receiverAddress, address(this), estimatedBTokenAmount, i_underlyingTokenAddress, _underlyingTokenAmount
        ) { } catch { }
        return estimatedBTokenAmount;
    }

    // ───────────────────────────── REDEEM ─────────────────────────────
    /**
     * @notice Redeems Birdieswap bTokens into vanilla underlying tokens.
     * @dev ERC4626 `redeem()` (PUSH model):
     *      1. Burns `_bTokenAmount` from owner.
     *      2. Sends equivalent proof tokens to strategy.
     *      3. Strategy returns underlying to vault → pushed to receiver.
     *
     * - Always available (even when paused) to guarantee user exit.
     * - Uses tolerance checks for both proof and underlying conversions.
     *
     * Emits {SingleWithdraw}.
     */
    function redeem(uint256 _bTokenAmount, address _receiverAddress, address _ownerAddress)
        public
        override
        nonReentrant
        onlyNonStrategy
        returns (uint256)
    {
        if (_bTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();
        if (_receiverAddress == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();

        address strategyAddress = s_strategyAddress;
        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(strategyAddress);
        IERC20 underlying = IERC20(i_underlyingTokenAddress);
        IERC20 proofToken = IERC20(i_proofTokenAddress);

        // ────────────────── PREVIEW VALIDATION ───────────────────
        uint256 estimatedProofTokenAmount = previewRedeem(_bTokenAmount);
        uint256 estimatedUnderlyingTokenAmount = strategy.previewRedeem(estimatedProofTokenAmount);
        if (estimatedProofTokenAmount == 0 || estimatedUnderlyingTokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();

        // ────────────────────── TOKEN FLOW ───────────────────────
        {
            address msgSender = _msgSender();
            if (msgSender != _ownerAddress) _spendAllowance(_ownerAddress, msgSender, _bTokenAmount);
        }
        _burn(_ownerAddress, _bTokenAmount);

        // ────────────────── STRATEGY REDEMPTION ──────────────────
        uint256 proofBefore = proofToken.balanceOf(address(this));
        proofToken.safeTransfer(strategyAddress, estimatedProofTokenAmount);
        // NOTE: Redeemed bToken and proof-token amounts may diverge slightly due to yield accrual or rounding.
        uint256 actualUnderlyingTokenAmount = strategy.redeem(estimatedProofTokenAmount);

        // ────────────────── TOLERANCE VERIFICATION ───────────────
        {
            if (actualUnderlyingTokenAmount == 0) revert BirdieswapSingleVaultV1__StrategyReturnedZero();
            if (!_isWithinTolerance(estimatedUnderlyingTokenAmount, actualUnderlyingTokenAmount)) {
                revert BirdieswapSingleVaultV1__UnderlyingDeltaOutOfTolerance();
            }

            uint256 proofAfter = proofToken.balanceOf(address(this));
            if (proofAfter > proofBefore) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
            uint256 delta = proofBefore - proofAfter;
            if (!_isWithinTolerance(estimatedProofTokenAmount, delta)) revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();

            uint256 recheckedProofTokenAmount = strategy.convertToShares(actualUnderlyingTokenAmount);
            if (!_isWithinTolerance(estimatedProofTokenAmount, recheckedProofTokenAmount)) {
                revert BirdieswapSingleVaultV1__ConversionOutOfTolerance();
            }
        }
        // ────────────────── UNDERLYING DELIVERY ──────────────────
        underlying.safeTransfer(_receiverAddress, actualUnderlyingTokenAmount);
        try i_event.emitSingleWithdraw(
            _receiverAddress, address(this), _bTokenAmount, i_underlyingTokenAddress, actualUnderlyingTokenAmount
        ) { } catch { }
        return actualUnderlyingTokenAmount;
    }

    /*//////////////////////////////////////////////////////////////
                         MAINTENANCE / MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Routine Upkeep ───────────────────────
    /**
     * @notice Executes routine compounding or maintenance in the strategy.
     * @dev Calls the strategy’s `doHardWork()` which typically claims rewards,reinvests yields, or rebalances. Transfers any idle
     *      underlying to the strategy before execution for full utilization.
     *
     * - Callable only by MANAGER_ROLE().
     * - Frequent automation-safe; non-reentrant and `onlyNonStrategy`.
     *
     * @return profitOrPerformance  Value reported by the strategy.
     */
    function doHardWork() external onlyManagerRole nonReentrant onlyNonStrategy returns (uint256) {
        IERC20 underlying = IERC20(i_underlyingTokenAddress);
        uint256 balance = underlying.balanceOf(address(this));
        address strategyAddress = s_strategyAddress;
        if (strategyAddress == address(0)) revert BirdieswapSingleVaultV1__InvalidStrategy();
        if (balance != 0) underlying.safeTransfer(strategyAddress, balance);
        return IBirdieswapSingleStrategyV1(strategyAddress).doHardWork();
    }

    // ──────────────────── Strategy Lifecycle ─────────────────────
    /**
     * @notice Proposes a new strategy contract to replace the current one.
     * @dev Sets `_newStrategy` as pending but does not activate it yet.
     *      Validation occurs immediately; activation happens later through `acceptStrategy()` (timelock-controlled).
     *
     * Emits {SingleStrategyProposed}.
     */
    function proposeStrategy(address _newStrategy) external onlyManagerRole {
        if (_validateStrategy(_newStrategy)) s_pendingStrategyAddress = _newStrategy;
        try i_event.emitSingleStrategyProposed(_newStrategy) { } catch { }
    }

    /**
     * @notice Activates the pending strategy after governance delay.
     * @dev Callable only by Timelock/UPGRADER_ROLE() once queued delay passes.
     *
     * Emits {SingleStrategyAccepted}.
     */
    function acceptStrategy() external onlyUpgraderRole {
        address newStrategy = s_pendingStrategyAddress;
        s_pendingStrategyAddress = address(0); // Clear pending immediately
        if (newStrategy == address(0)) _fail(newStrategy, SingleStrategyValidationReason.ZERO_ADDRESS);
        address oldStrategy = s_strategyAddress;
        if (_validateStrategy(newStrategy)) s_strategyAddress = newStrategy;
        try i_event.emitSingleStrategyAccepted(oldStrategy, newStrategy) { } catch { }
    }

    // ───────────────────────── Emergency ─────────────────────────
    /**
     * @notice Forces the strategy to unwind and return all underlying assets.
     * @dev For use only during severe protocol emergencies (e.g. insolvency).
     *      Transfers all proof tokens to the strategy and calls its `emergencyExit()`, pausing the vault afterward.
     *
     * Emits {SingleEmergencyExitTriggered}.
     */
    function emergencyExit() external onlyManagerRole onlyNonStrategy {
        address strategyAddress = s_strategyAddress;
        if (strategyAddress == address(0)) revert BirdieswapSingleVaultV1__InvalidStrategy();

        IERC20 underlying = IERC20(i_underlyingTokenAddress);
        IERC20 proof = IERC20(i_proofTokenAddress);
        uint256 proofBal = proof.balanceOf(address(this));
        proof.safeTransfer(strategyAddress, proofBal);

        uint256 beforeBal = underlying.balanceOf(address(this));
        uint256 exitAmt = IBirdieswapSingleStrategyV1(strategyAddress).emergencyExit();
        uint256 afterBal = underlying.balanceOf(address(this));

        if (afterBal < beforeBal || (afterBal - beforeBal) < exitAmt) revert BirdieswapSingleVaultV1__InvalidEmergencyExitReturn();
        if (exitAmt == 0) revert BirdieswapSingleVaultV1__StrategyReturnedZero();

        _pause();
        try i_event.emitSingleEmergencyExitTriggered(strategyAddress, exitAmt) { } catch { }
    }

    // ──────────────────────── Admin Tools ────────────────────────
    /**
     * @notice Rescues stray ERC20 tokens mistakenly sent to this contract.
     * @custom:governance Only callable by UPGRADER_ROLE().
     */
    function rescueERC20(address _tokenAddress, address _receiverAddress, uint256 _amount) external onlyUpgraderRole nonReentrant {
        if (_receiverAddress == address(0)) revert BirdieswapSingleVaultV1__ZeroAddressNotAllowed();
        if (_amount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();

        // Forbid rescuing core tokens
        if (_tokenAddress == i_underlyingTokenAddress) revert BirdieswapSingleVaultV1__CannotRescueUnderlyingToken();
        if (_tokenAddress == address(this)) revert BirdieswapSingleVaultV1__CannotRescueBToken();
        if (_tokenAddress == i_proofTokenAddress) revert BirdieswapSingleVaultV1__CannotRescueProofToken();

        IERC20(_tokenAddress).safeTransfer(_receiverAddress, _amount);
        try i_event.emitERC20RescuedFromSingleVault(_tokenAddress, _amount, _receiverAddress, _msgSender()) { } catch { }
    }

    // ──────────────────────── Monitoring ─────────────────────────
    /// @notice Deterministic helper for invariant test bounds.
    function pureExpectedAssetDelta(uint256 _proofAmount, uint256 _toleranceBp) external pure returns (uint256, uint256) {
        uint256 deviation = (_proofAmount * _toleranceBp) / 1e4;
        return (_proofAmount - deviation, _proofAmount + deviation);
    }

    /// @notice Returns deviation report between previewed and actual conversion rates (in basis points).
    function healthReport(uint256 _amount) external view returns (int256, int256, uint256) {
        if (_amount == 0 || s_strategyAddress == address(0)) return (int256(0), int256(0), uint256(0));

        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(s_strategyAddress);
        uint256 expectedProof = strategy.previewDeposit(_amount);
        if (expectedProof == 0) return (int256(0), int256(0), uint256(0));
        uint256 actualProof = strategy.convertToShares(_amount);

        int256 proofDev = (actualProof >= expectedProof)
            ? int256(((actualProof - expectedProof) * 1e4) / expectedProof)
            : -int256(((expectedProof - actualProof) * 1e4) / expectedProof);

        uint256 expectedUnder = strategy.previewRedeem(expectedProof);
        if (expectedUnder == 0) return (int256(proofDev), int256(0), uint256(0));

        uint256 actualUnder = strategy.convertToAssets(expectedProof);
        int256 underDev = (actualUnder >= expectedUnder)
            ? int256(((actualUnder - expectedUnder) * 1e4) / expectedUnder)
            : -int256(((expectedUnder - actualUnder) * 1e4) / expectedUnder);

        uint256 underRatioBp = (actualUnder * 1e4) / expectedUnder;
        return (proofDev, underDev, underRatioBp);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL UTILITIES
    //////////////////////////////////////////////////////////////*/

    // ──────────────────── Strategy Validation ────────────────────
    /// @dev Emits failure event and reverts with InvalidStrategy.
    function _fail(address _newStrategy, SingleStrategyValidationReason _reason) private {
        try i_event.emitSingleStrategyValidationFailed(_newStrategy, uint8(_reason)) { } catch { }
        revert BirdieswapSingleVaultV1__InvalidStrategy();
    }

    /// @dev Validates new strategy before marking as pending or active.
    function _validateStrategy(address _newStrategy) internal returns (bool) {
        if (_newStrategy == address(0)) _fail(_newStrategy, SingleStrategyValidationReason.ZERO_ADDRESS);
        if (_newStrategy == s_strategyAddress) _fail(_newStrategy, SingleStrategyValidationReason.SAME_AS_EXISTING);

        uint32 size;
        assembly {
            size := extcodesize(_newStrategy)
        }
        if (size == 0) _fail(_newStrategy, SingleStrategyValidationReason.NOT_CONTRACT);

        IBirdieswapSingleStrategyV1 strategy = IBirdieswapSingleStrategyV1(_newStrategy);

        // Vault linkage
        try strategy.getVault() returns (address vault) {
            if (vault != address(this)) _fail(_newStrategy, SingleStrategyValidationReason.VAULT_MISMATCH);
        } catch {
            _fail(_newStrategy, SingleStrategyValidationReason.VAULT_MISMATCH);
        }

        // Underlying consistency
        try strategy.asset() returns (address underlying) {
            if (underlying != i_underlyingTokenAddress) _fail(_newStrategy, SingleStrategyValidationReason.UNDERLYING_MISMATCH);
        } catch {
            _fail(_newStrategy, SingleStrategyValidationReason.UNDERLYING_MISMATCH);
        }

        // Proof token consistency
        try strategy.getTargetVault() returns (address proof) {
            if (proof != i_proofTokenAddress) _fail(_newStrategy, SingleStrategyValidationReason.PROOF_TOKEN_MISMATCH);
        } catch {
            _fail(_newStrategy, SingleStrategyValidationReason.PROOF_TOKEN_MISMATCH);
        }

        // Math Check A: assets -> shares -> assets must be within (abs || relative) tolerance
        {
            uint256 assetsProbe = 1e12; // generic probe; does not rely on decimals()
            uint256 sharesFromAssets;
            try strategy.previewDeposit(assetsProbe) returns (uint256 sfa) {
                sharesFromAssets = sfa;
                if (sfa == 0) _fail(_newStrategy, SingleStrategyValidationReason.DEPOSIT_PREVIEW_FAIL);
            } catch {
                _fail(_newStrategy, SingleStrategyValidationReason.DEPOSIT_PREVIEW_FAIL);
            }

            uint256 assetsBack;
            try strategy.previewRedeem(sharesFromAssets) returns (uint256 ab) {
                assetsBack = ab;
            } catch {
                _fail(_newStrategy, SingleStrategyValidationReason.MATH_INCONSISTENT);
            }

            if (!_isWithinTolerance(assetsProbe, assetsBack)) _fail(_newStrategy, SingleStrategyValidationReason.MATH_INCONSISTENT);
        }

        // Math Check B: shares -> assets -> shares must be within (abs || relative) tolerance
        {
            uint256 sharesProbe = 1e12;
            uint256 assetsFromShares;
            try strategy.previewMint(sharesProbe) returns (uint256 afs) {
                assetsFromShares = afs;
                if (afs == 0) _fail(_newStrategy, SingleStrategyValidationReason.WITHDRAW_PREVIEW_FAIL);
            } catch {
                // reuse existing enum for symmetry with legacy withdraw-preview checks
                _fail(_newStrategy, SingleStrategyValidationReason.WITHDRAW_PREVIEW_FAIL);
            }

            uint256 sharesBack;
            try strategy.previewWithdraw(assetsFromShares) returns (uint256 sb) {
                sharesBack = sb;
                if (sb == 0) _fail(_newStrategy, SingleStrategyValidationReason.WITHDRAW_PREVIEW_FAIL);
            } catch {
                _fail(_newStrategy, SingleStrategyValidationReason.WITHDRAW_PREVIEW_FAIL);
            }

            if (!_isWithinTolerance(sharesProbe, sharesBack)) _fail(_newStrategy, SingleStrategyValidationReason.MATH_INCONSISTENT);
        }

        return true;
    }

    // ────────────────────── Generic Helpers ──────────────────────
    /// @dev Validates token amount and resolves MAX_UINT sentinel.
    function _validateTokenAmount(address _userAddress, address _tokenAddress, uint256 _tokenAmount) internal view returns (uint256) {
        if (_tokenAmount == 0) revert BirdieswapSingleVaultV1__InvalidAmount();
        if (_tokenAmount == type(uint256).max) _tokenAmount = IERC20(_tokenAddress).balanceOf(_userAddress);
        return _tokenAmount;
    }

    /**
     * @notice Checks whether `_actualAmount` is within absolute or relative tolerance of `_estimatedAmount`.
     * @dev
     * - Returns `true` if:
     *     1. |_estimatedAmount - _actualAmount| ≤ i_absoluteToleranceInWei, OR
     *     2. |_estimatedAmount - _actualAmount| ≤ (_estimatedAmount * i_relativeToleranceInBp) / 10_000.
     *
     * - The function enforces both bounds:
     *     - Absolute tolerance (fixed precision): caps minimal rounding noise (e.g., ≤ 2 wei).
     *     - Relative tolerance (percentage): guards against proportional drift (e.g., ≤ 1 bp = 0.01%).
     *
     * - Used in all deposit/mint/redeem/withdraw flows to assert consistency between previewed and actual conversions
     *   across both ERC4626 layers (vault  strategy).
     */
    function _isWithinTolerance(uint256 _estimatedAmount, uint256 _actualAmount) internal view returns (bool) {
        if (_estimatedAmount == _actualAmount) return true;
        if (_estimatedAmount == 0) return _actualAmount == 0;

        uint256 diff;
        unchecked {
            diff = (_estimatedAmount > _actualAmount) ? _estimatedAmount - _actualAmount : _actualAmount - _estimatedAmount;
        }
        if (diff <= i_absoluteToleranceInWei) return true;

        uint256 allowed = Math.mulDiv(_estimatedAmount, i_relativeToleranceInBp, 10_000);
        return diff <= allowed;
    }
}
/*//////////////////////////////////////////////////////////////
                        END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant The vault’s totalAssets() always equals its on-chain proof-token balance, ensuring ERC4626 accounting fidelity.
/// @custom:invariant totalUnderlyingBalance() ≥ convertToAssets(totalSupply()); the vault can always fully redeem all user shares.
/// @custom:invariant Strategy address (s_strategyAddress) is immutable post-activation and never reverts to address(0).
/// @custom:invariant No function can mint, burn, or transfer bTokens except via standard ERC4626 flows (deposit/mint/withdraw/redeem).
/// @custom:invariant Pausing only disables new deposits/mints — withdrawals and redemptions always remain available to users.
