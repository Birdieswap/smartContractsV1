// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { ERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "../lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "../lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { Pausable } from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "../src/BirdieswapConfigV1.sol";
import { BirdieswapRoleSignaturesV1 } from "./BirdieswapRoleSignaturesV1.sol";
import { IBirdieswapDualStrategyV1 } from "./interfaces/IBirdieswapDualStrategyV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapRoleRouterV1 } from "./interfaces/IBirdieswapRoleRouterV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  Birdieswap Dual Vault V1 — Uniswap V3–style dual-asset ERC4626 vault
 * @author Birdieswap Team
 *
 * @notice Core dual-asset vault managing Uniswap V3–style liquidity positions via a delegated strategy. Users (or the Router)
 *         deposit two ERC20 “bTokens” (Birdieswap SingleVault proof tokens) and receive ERC20 vault shares (“blpToken”) representing
 *         proportional ownership of the vault’s Uniswap V3 LP position (custodied as an ERC721). Redemptions return both bTokens in
 *         their pro-rata amounts.
 *
 * @dev Architecture overview:
 *      - **Vault responsibilities:** Custodies the Uniswap position NFT, mints/burns vault shares, and enforces deposit/redemption logic.
 *        Implements ERC4626 for compatibility but disables standard single-asset flows.
 *      - **Strategy responsibilities:** Executes position rebalancing, fee compounding, and liquidity management. The vault holds the NFT;
 *        the strategy is granted ERC721 approval to act on it.
 *      - **Separation of concerns:** Vault and strategy are non-upgradeable, isolated contracts connected through governance-controlled
 *        assignment.
 *
 * @dev Security model (auditor summary):
 *      - **Upgrade control:** The vault is non-upgradeable. Strategy replacement is governed via Timelock-gated proposal and acceptance.
 *        Each replacement revokes prior ERC721 and ERC20 approvals automatically.
 *      - **Reentrancy protection:**
 *          • {nonReentrant} — guards user entrypoints.
 *          • `strategyCallLock` — mutex preventing cross-function reentrancy through callbacks.
 *          • CEI pattern — effects occur strictly before external interactions.
 *      - **Token safety:** All ERC20 interactions use {SafeERC20}; no ERC777 hooks or unsafe callbacks are relied on.
 *      - **ERC4626 compliance:** Inherits for interface compatibility only. All single-asset entrypoints (deposit/mint/withdraw/redeem)
 *        revert intentionally; custom dual-token methods replace them.
 *
 * @dev Governance policy (operational requirements):
 *      1. All strategy updates must be scheduled and executed through the project’s TimelockController with a non-zero delay
 *         (recommended ≥ 24 hours).
 *      2. Only the TimelockController may hold {i_upgraderRole}.
 *      3. {i_defaultAdminRole} must be transferred to the TimelockController post-deploy and renounced by EOAs.
 *      4. When activating a new strategy, governance must verify that `getDualVaultAddress() == address(this)`.
 *      5. Monitor {StrategyAccepted}, NFT {Approval}/{Transfer}, and {EmergencyExitTriggered} events from event relayer for state changes.
 *      6. During emergencies, invoke {pause()} to freeze deposits, then {emergencyExit()} to repatriate assets.
 *      7. At construction or governance step, assert both bTokens are non-rebasing and non-fee-on-transfer. Optionally perform a one-shot
 *         transfer probe to detect fees.
 *      8. bTokens MUST be plain ERC20: non-rebasing, non-fee-on-transfer, no ERC777 hooks.
 *
 * @dev Deployment lifecycle:
 *      - The vault is deployed first with no active strategy (`s_strategyAddress == address(0)`).
 *      - The strategy is then deployed referencing this vault.
 *      - Governance (via Timelock) executes a two-step activation: {proposeStrategy()} → {acceptStrategy()}. This bootstrap state (no
 *        strategy active yet) is expected and non-fatal by design.
 *
 * @custom:governance All strategy upgrades must be scheduled through governance and executed by the TimelockController after the required
 *                    delay. Direct, immediate upgrades are disallowed.
 */
contract BirdieswapDualVaultV1 is ERC4626, Pausable, ReentrancyGuard, BirdieswapRoleSignaturesV1 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────────── Generic ───────────────────────────
    // Basic precondition and parameter validation.
    /// @notice Thrown when the caller lacks required role permissions.
    error BirdieswapDualVaultV1__UnauthorizedAccess();
    /// @notice Thrown when an expected non-zero address parameter is zero.
    error BirdieswapDualVaultV1__ZeroAddressNotAllowed();
    /// @notice Thrown when either bToken deposit amount is zero.
    error BirdieswapDualVaultV1__ZeroAmountNotAllowed();
    /// @notice Thrown when a supplied amount is invalid (zero or inconsistent).
    error BirdieswapDualVaultV1__InvalidAmount();

    // ────────────────── Strategy Lifecycle Management ────────────
    // Enforces the correct proposal → validation → acceptance flow for strategies.
    /// @notice Thrown when no active strategy is configured but one is required.
    error BirdieswapDualVaultV1__NoActiveStrategy();
    /// @notice Thrown when a proposed or pending strategy is invalid, not a contract, or fails validation.
    error BirdieswapDualVaultV1__InvalidStrategy();
    /// @notice Thrown when allowances to the previous strategy are not fully revoked prior to replacement.
    error BirdieswapDualVaultV1__OldStrategyAllowanceNotRevoked();
    /// @notice Thrown when the vault does not currently own the Uniswap position NFT.
    error BirdieswapDualVaultV1__VaultNotNFTOwner();
    /// @notice Thrown when an unexpected or unapproved NFT is sent to the vault.
    error BirdieswapDualVaultV1__UnexpectedNFTReceived();

    // ─────────────────── Liquidity & Accounting ──────────────────
    // Captures inconsistencies in strategy-reported liquidity or vault share math.
    /// @notice Thrown when reported liquidity exceeds Uniswap’s uint128 bound.
    error BirdieswapDualVaultV1__LiquidityOverflow();
    /// @notice Thrown when strategy liquidity decreases unexpectedly after a deposit.
    error BirdieswapDualVaultV1__LiquidityDecreased();
    /// @notice Thrown when strategy-reported liquidity or deltas are internally inconsistent.
    error BirdieswapDualVaultV1__InconsistentLiquidity();
    /// @notice Thrown when the strategy fails to increase liquidity during a deposit.
    error BirdieswapDualVaultV1__NoLiquidityReceived();
    /// @notice Thrown when attempting redemption while total vault share supply is zero.
    error BirdieswapDualVaultV1__NoSharesExist();

    // ────────────────────── Security / Locks ─────────────────────
    // Guards against reentrancy and cross-function callback loops.
    /// @notice Thrown on attempted cross-function reentrancy through a strategy callback.
    error BirdieswapDualVaultV1__ReentrancyViaStrategy();

    // ─────────────────── Disabled ERC-4626 Paths ─────────────────
    // Standard single-asset entrypoints are intentionally unsupported for dual-asset design.
    /// @notice Single-asset mint() path is disabled; use dual-asset {deposit()} instead.
    error BirdieswapDualVaultV1__MintNotSupported(uint256 _shares, address _receiver);
    /// @notice Single-asset withdraw() path is disabled; use dual-asset {redeem()} instead.
    error BirdieswapDualVaultV1__WithdrawNotSupported(uint256 _assets, address _receiver, address _owner);
    /// @notice Single-asset deposit() path is disabled; must deposit both bTokens together.
    error BirdieswapDualVaultV1__MustDepositTwoTokens(uint256 _assets, address _receiver);
    /// @notice Single-asset redeem() path is disabled; must redeem through dual-asset flow.
    error BirdieswapDualVaultV1__MustRedeemProperly(uint256 _shares, address _receiver, address _owner);

    // ───────────────── Governance & Rescue Safety ────────────────
    // Restricts token recovery to non-core assets and guards against misuse.
    /// @notice Thrown when attempting to rescue core bToken0 or bToken1.
    error BirdieswapDualVaultV1__CannotRescueBToken();
    /// @notice Thrown when attempting to rescue the vault’s own blpToken.
    error BirdieswapDualVaultV1__CannotRescueBLPToken();
    /// @notice Thrown when invalid parameters have been passed as configuration.
    error BirdieswapDualVaultV1__InvalidConfiguration();

    /*//////////////////////////////////////////////////////////////
                                  ENUM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enumerates possible failure reasons during strategy validation.
     * @dev    All values represent specific failure states; there is no success variant.
     */
    enum DualStrategyValidationReason {
        ZERO_ADDRESS, // 0 — Strategy address is zero.
        SAME_AS_EXISTING, // 1 — Matches the current active strategy.
        NOT_CONTRACT, // 2 — Target has no code (EOA or undeployed).
        VAULT_MISMATCH, // 3 — getDualVaultAddress() ≠ address(this).
        ASSET_MISMATCH, // 4 — bToken pair mismatch between vault and strategy.
        INVALID_POOL_ADDRESS // 5 — Strategy reports an invalid or zero pool address.

    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────────── Version ───────────────────────────
    /// @notice Human-readable contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapDualVaultV1";

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // ─────────────────── Immutable Core References ───────────────
    // Immutable component routers/relayers used across protocol logic.

    /// @notice Role router providing centralized access control across protocol modules.
    IBirdieswapRoleRouterV1 private immutable i_role;

    /// @notice Event relayer responsible for re-emitting standardized protocol events.
    IBirdieswapEventRelayerV1 private immutable i_event;

    // ─────────────────── Immutable Vault Composition ─────────────
    // Defines the vault’s dual-asset pairing for deterministic and permanent asset handling.

    /// @notice Ordered pair of bTokens (wrapping underlying ERC20s via SingleVaults).
    /// @dev    Ordering (bToken0 < bToken1) is deterministic and immutable.
    address private immutable i_bToken0Address;
    address private immutable i_bToken1Address;

    // ──────────────────────── Configuration ───────────────────────
    /// @dev Allowed rounding tolerance (±1 wei) between previewed and actual conversions.
    uint256 private immutable i_roundingTolerance;

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Strategy State ──────────────────────
    // Tracks the active and pending strategy contracts and internal lock flag.
    /// @notice Active strategy authorized to manage the position NFT and handle liquidity.
    address private s_strategyAddress;

    /// @dev Internal reentrancy flag for cross-function protection on strategy callbacks.
    /// @dev Packed between two address slots to minimize SSTORE cost.
    bool private s_strategyCallLockActive;

    /// @notice Pending strategy proposed for activation via {acceptStrategy}.
    address private s_pendingStrategyAddress;

    address private s_positionManagerAddress;
    uint256 private s_tokenId;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes the dual-asset vault with immutable configuration references and ordered bToken pairing.
     *
     * @dev Constructor rationale and sequence:
     *      1. Validates all provided addresses are non-zero.
     *      2. Caches immutable core references ({i_role}, {i_event}).
     *      3. Orders the bToken pair deterministically (bToken0 < bToken1).
     *      4. Initializes the ERC4626 base using a dummy ERC20 token for interface compliance only.
     *
     * @param configAddress_       Address of the global configuration contract.
     * @param bToken0Address_      Address of bToken0 (Birdieswap SingleVault proof token).
     * @param bToken1Address_      Address of bToken1 (Birdieswap SingleVault proof token).
     * @param dummyErc20Address_   ERC20 used solely to initialize the ERC4626 base; its metadata is unused.
     * @param name_                ERC20 name for the vault’s share token (blpToken).
     * @param symbol_              ERC20 symbol for the vault’s share token.
     * @param roleRouterAddress_   Address of the centralized RoleRouter providing access-control queries.
     * @param eventRelayerAddress_ Address of the EventRelayer responsible for unified event emission.
     *
     * @custom:governance Post-deployment requirements:
     *                    1. Transfer {i_defaultAdminRole} to the TimelockController and renounce from EOAs.
     *                    2. Verify Timelock delay ≥ 24 hours for all queued actions.
     *                    3. Activate the initial strategy through the Timelock-managed {acceptStrategy()} flow.
     */
    constructor(
        address configAddress_,
        address bToken0Address_,
        address bToken1Address_,
        address dummyErc20Address_,
        string memory name_,
        string memory symbol_,
        address roleRouterAddress_,
        address eventRelayerAddress_
    ) ERC4626(IERC20(dummyErc20Address_)) ERC20(name_, symbol_) {
        // ─────────────── Core reference validation ───────────────
        if (configAddress_ == address(0)) revert BirdieswapDualVaultV1__ZeroAddressNotAllowed();
        if (roleRouterAddress_ == address(0)) revert BirdieswapDualVaultV1__ZeroAddressNotAllowed();
        if (eventRelayerAddress_ == address(0)) revert BirdieswapDualVaultV1__ZeroAddressNotAllowed();

        BirdieswapConfigV1 config;
        config = BirdieswapConfigV1(configAddress_);
        i_role = IBirdieswapRoleRouterV1(roleRouterAddress_);
        i_event = IBirdieswapEventRelayerV1(eventRelayerAddress_);

        // ───────────────────── Config values ─────────────────────
        i_roundingTolerance = config.i_roundingTolerance();
        if (i_roundingTolerance > 2) revert BirdieswapDualVaultV1__InvalidConfiguration();

        // ────────────── Token parameter validation ───────────────
        if (bToken0Address_ == address(0) || bToken1Address_ == address(0) || dummyErc20Address_ == address(0)) {
            revert BirdieswapDualVaultV1__ZeroAddressNotAllowed();
        }

        // ─────────────── Deterministic token ordering ────────────
        // Ensures consistent and predictable asset ordering across vault and strategy contracts.
        (bToken0Address_ > bToken1Address_)
            ? (i_bToken0Address, i_bToken1Address) = (bToken1Address_, bToken0Address_)
            : (i_bToken0Address, i_bToken1Address) = (bToken0Address_, bToken1Address_);
        if (bToken0Address_ == bToken1Address_) revert BirdieswapDualVaultV1__InvalidConfiguration();
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/
    // Access control and security guards for core operations.

    /**
     * @notice Restricts function access to accounts holding DEFAULT_ADMIN_ROLE.
     *
     * @dev    Used for privileged administrative operations such as {rescueERC20()}.
     *
     * @custom:security Ensures only governance-approved operators can use top level governance features.
     */
    modifier onlyDefaultAdminRole() {
        if (!i_role.hasRoleGlobal(DEFAULT_ADMIN_ROLE, msg.sender)) revert BirdieswapDualVaultV1__UnauthorizedAccess();
        _;
    }

    /**
     * @notice Restricts function access to accounts holding UPGRADER_ROLE (typically the TimelockController).
     *
     * @dev    Used for privileged administrative operations such as {acceptStrategy()} and {rescueERC20()}.
     *         Ensures all upgrade or recovery actions are executed only after the Timelock delay elapses.
     *
     * @custom:security Guarantees governance-level time-delayed execution for critical vault operations.
     */
    modifier onlyUpgraderRole() {
        if (!i_role.hasRoleGlobal(UPGRADER_ROLE, msg.sender)) revert BirdieswapDualVaultV1__UnauthorizedAccess();
        _;
    }

    /**
     * @notice Restricts function access to accounts holding UNPAUSER_ROLE.
     *
     * @dev    Used for lifting pause operations such as {unpause()}.
     *         Ensures all unpause are executed only after the Timelock delay elapses.
     *
     * @custom:security Guarantees governance-level time-delayed execution for critical vault operations.
     */
    modifier onlyUnpauserRole() {
        if (!i_role.hasRoleGlobal(UNPAUSER_ROLE, msg.sender)) revert BirdieswapDualVaultV1__UnauthorizedAccess();
        _;
    }

    /**
     * @notice Restricts function access to accounts holding i_managerRole.
     *
     * @dev    Used for routine maintenance or strategy-management operations,
     *         including {proposeStrategy()}, {doHardWork()}.
     *
     * @custom:security Ensures only governance-approved operators can modify liquidity or strategy state.
     */
    modifier onlyManagerRole() {
        if (!i_role.hasRoleGlobal(MANAGER_ROLE, msg.sender)) revert BirdieswapDualVaultV1__UnauthorizedAccess();
        _;
    }

    /**
     * @notice Restricts function access to accounts holding either GUARDIAN_ROLE or GUARDIAN_FULL_ROLE.
     *
     * @dev    Used for emergency operations such as {pause()}.
     *         Roles are resolved globally through the centralized {i_role} router.
     *
     * @custom:security Enforces protocol-level guardian hierarchy defined in {BirdieswapConfigV1}.
     */
    modifier onlyGuardianRole() {
        if (!(i_role.hasRoleGlobal(GUARDIAN_ROLE, msg.sender) || i_role.hasRoleGlobal(GUARDIAN_FULL_ROLE, msg.sender))) {
            revert BirdieswapDualVaultV1__UnauthorizedAccess();
        }
        _;
    }

    /**
     * @notice Prevents nested or cross-function reentrancy originating from strategy callbacks.
     *
     * @dev    Applied to all external functions that interact with the strategy
     *         (e.g., {deposit()}, {redeem()}, {doHardWork()}, {emergencyExit()}).
     *
     * @dev Mechanism and rationale:
     *      - **Layered defense:** Works alongside {ReentrancyGuard.nonReentrant} to block both internal and external
     *        reentrancy vectors.
     *      - **Lock behavior:** Sets {s_strategyCallLockActive = true} for the duration of the call, reverting if another
     *        strategy-touching entrypoint is invoked within the same transaction.
     *      - **Scope:** Operates per-transaction; unlike {pause()}, it does not affect subsequent transactions.
     *      - **Gas optimization:** The flag is tightly packed between adjacent storage slots to minimize SSTORE costs.
     *
     * @custom:security Protects against malicious strategy callbacks, reentrant control flow, and cross-function recursion.
     */
    modifier strategyCallLock() {
        if (s_strategyCallLockActive) revert BirdieswapDualVaultV1__ReentrancyViaStrategy();
        s_strategyCallLockActive = true;
        _;
        s_strategyCallLockActive = false;
    }

    /**
     * @notice Ensures that a valid active strategy is configured before executing any liquidity-affecting operation.
     *
     * @dev    Applied to safety-critical functions such as {deposit()}, {redeem()}, {doHardWork()}, and {emergencyExit()}.
     *         Reverts with {BirdieswapDualVaultV1__NoActiveStrategy} if {s_strategyAddress} is unset.
     *         Omitted from view-only functions for gas efficiency; such calls revert naturally downstream.
     *         Temporary uninitialized states are permitted immediately post-deployment until {acceptStrategy()} activates.
     *
     * @custom:invariant User-facing operations can execute only when a valid strategy is active and properly linked to this vault.
     */
    modifier whenStrategyActive() {
        if (s_strategyAddress == address(0)) revert BirdieswapDualVaultV1__NoActiveStrategy();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT CONTROL FLOW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Globally pauses all user-facing interactions with the vault during an emergency or maintenance window.
     *         Redemptions remain permitted to allow user exits.
     *
     * @dev Operational context:
     *      - **Access control:** Restricted to {onlyGuardianRole()} — typically a guardian or risk-response operator.
     *      - **Scope:** Disables functions guarded by {whenNotPaused}, such as {deposit()} and {doHardWork()}.
     *      - **Distinction:**
     *          • `pause()` is a *global circuit breaker* effective across transactions.
     *          • `strategyCallLock` is a *per-transaction mutex* for intra-tx reentrancy defense.
     *      - **Usage:** Commonly invoked before {emergencyExit()} or strategy migration to block new deposits while
     *        preserving safe withdrawals.
     *
     * @custom:security Always verify strategy state and vault integrity before unpausing.
     */
    function pause() external onlyGuardianRole {
        _pause();
        try i_event.emitDepositsPaused(msg.sender) { } catch { }
    }

    /**
     * @notice Resumes normal vault operations after a prior {pause()}, restoring deposits and strategy operations.
     *
     * @dev Operational context:
     *      - **Access control:** Restricted to {onlyGuardianRole()}.
     *      - **Safety:** Should only be invoked after confirming that the strategy, pool, and vault balances are consistent.
     *      - **Relation:** The internal {strategyCallLock} remains permanently active regardless of pause state.
     *
     * @custom:governance Notify frontends and off-chain indexers before resuming deposits.
     */
    function unpause() external onlyUnpauserRole {
        _unpause();
        try i_event.emitDepositsUnpaused(msg.sender) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the contract version string.
     *
     * @dev    Used by off-chain indexers or version managers to verify deployment identity.
     *         Pure function — reads the static constant {CONTRACT_VERSION}.
     *
     * @return Contract version identifier as a human-readable string.
     */
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /**
     * @notice Returns the currently active strategy contract address.
     * @dev    Returns address(0) if no strategy has been activated yet.
     * @return Address of the active strategy.
     */
    function getStrategyAddress() external view returns (address) {
        return s_strategyAddress;
    }

    /**
     * @notice Returns whether the strategy has been activated at least once.
     * @dev    Useful for external integrations; avoids additional SLOADs on internal hot paths.
     * @return True if a strategy is active, false otherwise.
     */
    function isStrategyActive() external view returns (bool) {
        return s_strategyAddress != address(0);
    }

    /**
     * @notice Returns the underlying Uniswap V3 pool address as reported by the strategy.
     * @dev    Strategy is expected to report an accurate, non-zero pool address.
     * @dev    Reverts if no strategy is active; use {isStrategyActive()} before calling.
     * @return Address of the Uniswap V3 pool.
     */
    function getPoolAddress() external view returns (address) {
        if (s_strategyAddress == address(0)) return address(0);
        return IBirdieswapDualStrategyV1(s_strategyAddress).getPoolAddress();
    }

    /**
     * @notice Returns the Uniswap V3 fee tier used by the strategy, in hundredths of a bip (e.g., 500 = 0.05%).
     * @dev    Directly reads through to the strategy’s internal pool configuration.
     * @dev    Reverts if no strategy is active; use {isStrategyActive()} before calling.
     * @return Uniswap V3 fee tier.
     */
    function getFeeTier() external view returns (uint24) {
        if (s_strategyAddress == address(0)) return 0;
        return IBirdieswapDualStrategyV1(s_strategyAddress).getFeeTier();
    }

    /**
     * @notice Returns the configured address of bToken0 (first token in the ordered pair).
     * @dev    Immutable after deployment; defines deterministic vault composition.
     * @return Address of bToken0.
     */
    function getToken0Address() external view returns (address) {
        return i_bToken0Address;
    }

    /**
     * @notice Returns the configured address of bToken1 (second token in the ordered pair).
     * @dev    Immutable after deployment; defines deterministic vault composition.
     * @return Address of bToken1.
     */
    function getToken1Address() external view returns (address) {
        return i_bToken1Address;
    }

    /**
     * @notice Returns the total assets managed by the vault as per ERC4626 standard, expressed as Uniswap V3 liquidity.
     * @dev    Maps directly to the active strategy’s current liquidity (uint128) cast to uint256.
     * @return Total assets (strategy liquidity) held on behalf of vault participants.
     */
    function totalAssets() public view override returns (uint256) {
        address strategyAddress = s_strategyAddress;
        if (strategyAddress == address(0)) return 0;
        return uint256(_strategyLiquidity());
    }

    /**
     * @notice Returns the combined total of both bTokens held across the vault and its active strategy.
     *         Provides a full accounting snapshot of underlying assets regardless of custody location.
     *
     * @dev Accounting rationale:
     *      - **Comprehensive coverage:** Includes (a) vault-held balances, (b) strategy-held idle tokens, and
     *        (c) tokens represented as in-position liquidity.
     *      - **Data source:** Combines on-chain balances with {IBirdieswapDualStrategyV1.getPositionComposition()}.
     *      - **Trust assumption:** Strategy reports accurate values; governance should periodically verify these.
     *      - **Usage:** Designed for analytics and off-chain monitoring, not for redemption or internal accounting.
     *
     * @dev Returns 0 if no strategy is active; call {isStrategyActive()} before invoking.
     *
     * @return bToken0Address  Address of bToken0.
     * @return bToken1Address  Address of bToken1.
     * @return bToken0Amount   Aggregate total of bToken0 held across vault and strategy.
     * @return bToken1Amount   Aggregate total of bToken1 held across vault and strategy.
     */
    function totalBTokens() public view returns (address, address, uint256, uint256) {
        address strategyAddress = s_strategyAddress;
        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);
        if (s_strategyAddress == address(0)) return (i_bToken0Address, i_bToken1Address, 0, 0);

        (,, uint256 bToken0Amount, uint256 bToken1Amount) = IBirdieswapDualStrategyV1(strategyAddress).getPositionComposition();

        bToken0Amount += bToken0.balanceOf(strategyAddress) + bToken0.balanceOf(address(this));
        bToken1Amount += bToken1.balanceOf(strategyAddress) + bToken1.balanceOf(address(this));

        return (i_bToken0Address, i_bToken1Address, bToken0Amount, bToken1Amount);
    }

    /**
     * @notice ERC721 receiver hook enabling the vault to safely hold Uniswap V3 position NFTs.
     *
     * @dev    Validates that the NFT originates from the authorized position manager and corresponds to the active
     *         strategy’s tracked token ID. Rejects unexpected or unapproved NFTs.
     * @dev    Emits {NFTReceived} via the {i_event} relayer for off-chain monitoring.
     *
     * @custom:security Prevents malicious NFT transfers and guarantees correct strategy-token pairing.
     *
     * @param _operator Address initiating the transfer.
     * @param _from     Previous owner of the NFT (expected to be the strategy).
     * @param _tokenId  Token ID of the received NFT.
     * @param _data     Optional call data forwarded by the sender.
     *
     * @return Selector confirming safe receipt per ERC721 standard.
     */
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data) external returns (bytes4) {
        if (msg.sender != s_positionManagerAddress) revert BirdieswapDualVaultV1__UnexpectedNFTReceived();
        if (_tokenId != s_tokenId) revert BirdieswapDualVaultV1__UnexpectedNFTReceived();

        try i_event.emitNFTReceived(_operator, _from, _tokenId, _data) { } catch { }
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                 GOVERNANCE / MANAGEMENT / MAINTENANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stages a new strategy for potential activation. The proposed strategy is immediately validated and, if
     *         successful, recorded as the pending strategy awaiting Timelock acceptance.
     *
     * @dev Governance & security rationale:
     *      - **Access control:** Callable only by {onlyManagerRole()} — typically the governance operations multisig or
     *        a designated strategist.
     *      - **Immediate validation:** {_validateStrategy} performs a full structural sanity check ensuring the proposed
     *        contract matches this vault, references the correct bTokens, and links to a valid pool.
     *      - **Deferred activation:** A validated strategy remains pending until {acceptStrategy()} is executed by the
     *        TimelockController after the required delay period.
     *      - **Gas rationale:** Validation executes inline to avoid redundant caching. No custody operations occur here,
     *        so the process remains cost-efficient and non-intrusive.
     *
     * @param _newStrategy Address of the proposed strategy contract to be validated and staged.
     *
     * @custom:emits Emits {StrategyProposed} regardless of validation success. Integrators can listen for this event to
     *               track governance proposals.
     */
    function proposeStrategy(address _newStrategy) external onlyManagerRole {
        if (_validateStrategy(_newStrategy)) s_pendingStrategyAddress = _newStrategy;
        try i_event.emitDualStrategyProposed(_newStrategy) { } catch { }
    }

    /**
     * @notice Finalizes a strategy upgrade previously proposed via {proposeStrategy()}. Activates the new strategy,
     *         revokes old allowances, validates invariants, and grants ERC20 + ERC721 approvals.
     *
     * @dev Governance & security rationale:
     *      - **Timelock-only:** Callable exclusively by {onlyUpgraderRole()} — typically the TimelockController, ensuring
     *        mandatory governance delay between proposal and activation.
     *      - **Validation:** Revalidates the pending strategy via {_validateStrategy} to confirm vault linkage, token
     *        pairing, and pool integrity.
     *      - **Allowance hygiene:** All ERC20 approvals to the old strategy are revoked and verified to be zero before
     *        new permissions are granted.
     *      - **NFT custody:** Confirms the vault remains owner of the Uniswap V3 position NFT before granting approval.
     *      - **Gas rationale:** Avoids redundant reads (e.g., zero checks) for cost efficiency without compromising safety.
     *
     * @custom:flow Sequence:
     *      1. Governance proposes a strategy via {proposeStrategy()}.
     *      2. After the Timelock delay, {acceptStrategy()} is executed.
     *      3. Old strategy approvals are revoked; new ones granted.
     *      4. The vault’s NFT and bTokens are handed over to the new strategy.
     *
     * @custom:emits Emits {DualStrategyAccepted} on success, or {DualStrategyValidationFailed} if validation reverts via event relayer.
     */
    function acceptStrategy() external onlyUpgraderRole {
        address newStrategyAddress = s_pendingStrategyAddress;
        s_pendingStrategyAddress = address(0);

        if (newStrategyAddress == address(0)) _failValidation(newStrategyAddress, DualStrategyValidationReason.ZERO_ADDRESS);

        address oldStrategy = s_strategyAddress;

        if (_validateStrategy(newStrategyAddress)) {
            IERC20 bToken0 = IERC20(i_bToken0Address);
            IERC20 bToken1 = IERC20(i_bToken1Address);

            // ─────────────── Revoke old allowances ───────────────
            if (oldStrategy != address(0)) {
                bToken0.forceApprove(oldStrategy, 0);
                bToken1.forceApprove(oldStrategy, 0);

                if (bToken0.allowance(address(this), oldStrategy) != 0 || bToken1.allowance(address(this), oldStrategy) != 0) {
                    revert BirdieswapDualVaultV1__OldStrategyAllowanceNotRevoked();
                }
            }

            // ─────────────── Activate new strategy ───────────────
            s_strategyAddress = newStrategyAddress;
            IBirdieswapDualStrategyV1 newStrategy = IBirdieswapDualStrategyV1(newStrategyAddress);

            s_positionManagerAddress = newStrategy.getPositionManagerAddress();
            IERC721 nft = IERC721(s_positionManagerAddress);
            s_tokenId = newStrategy.getTokenId();

            // Verify NFT custody and grant approval to new strategy.
            if (nft.ownerOf(s_tokenId) != address(this)) revert BirdieswapDualVaultV1__VaultNotNFTOwner();

            nft.approve(newStrategyAddress, s_tokenId);
            // ERC721 single-token approval automatically clears prior approvals.

            // Grant unlimited ERC20 allowance to the fully trusted new strategy.
            bToken0.forceApprove(newStrategyAddress, type(uint256).max);
            bToken1.forceApprove(newStrategyAddress, type(uint256).max);

            try i_event.emitDualStrategyAccepted(oldStrategy, newStrategyAddress) { } catch { }
        }
    }

    /**
     * @notice Performs routine maintenance on the strategy — harvesting rewards, reinvesting yields, and rebalancing
     *         liquidity according to strategy-defined logic. May run even while paused.
     *
     * @dev Governance & operational rationale:
     *      - **Access control:** Callable only by {onlyManagerRole()}. Typically executed by governance or a keeper.
     *      - **Fund flow:** Transfers any idle bTokens from the vault to the active strategy before invoking
     *        {IBirdieswapDualStrategyV1.doHardWork()}.
     *      - **Return value:** Returns the updated liquidity value as reported by the strategy post-compounding.
     *      - **Gas rationale:** Omits redundant liquidity comparisons; these add cost without improving safety.
     *
     * @return newLiquidity Updated total liquidity reported by the strategy after compounding and rebalancing.
     */
    function doHardWork() external onlyManagerRole strategyCallLock whenStrategyActive returns (uint256) {
        address strategyAddress = s_strategyAddress;
        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);

        uint256 bToken0Amount = bToken0.balanceOf(address(this));
        uint256 bToken1Amount = bToken1.balanceOf(address(this));

        bToken0.safeTransfer(strategyAddress, bToken0Amount);
        bToken1.safeTransfer(strategyAddress, bToken1Amount);

        return IBirdieswapDualStrategyV1(strategyAddress).doHardWork();
    }

    /**
     * @notice Executes an emergency withdrawal from the active strategy, pulling all managed bTokens and liquidity
     *         back into the vault for safekeeping.
     *
     * @dev Governance & security rationale:
     *      - **Access control:** Callable only by {onlyManagerRole()} — typically governance or an emergency operator.
     *      - **Usage:** Should be used only during protocol emergencies or strategy compromise.
     *      - **Mechanism:** Calls {IBirdieswapDualStrategyV1.emergencyExit()}, which must unwind all positions and return
     *        the bTokens to the vault.
     *      - **Custody assurance:** After execution, all assets are held directly by the vault; no external strategy
     *        retains liquidity or allowances.
     *      - **Event emission:** Emits {EmergencyExitTriggered} with withdrawn amounts for monitoring and accounting.
     *
     * @custom:security This is a critical governance-only safety function to be used strictly under emergency conditions.
     */
    function emergencyExit() external nonReentrant strategyCallLock onlyManagerRole whenStrategyActive {
        (uint256 amount0, uint256 amount1) = IBirdieswapDualStrategyV1(s_strategyAddress).emergencyExit();
        _pause();
        try i_event.emitDualEmergencyExitTriggered(s_strategyAddress, amount0, amount1) { } catch { }
    }

    /**
     * @notice Recovers stray or non-core ERC20 tokens accidentally sent to the vault. Designed for governance-led
     *         recovery only and does not affect user funds or strategy liquidity.
     *
     * @dev Governance & safety rationale:
     *      - **Access control:** Callable only by {onlyUpgraderRole()} — typically the TimelockController, enforcing delay.
     *      - **Scope limitation:** Forbids rescuing bToken0, bToken1, or the vault’s own blpToken, as these represent
     *        core protocol assets.
     *      - **Fund safety:** Transfers only vault-held tokens; never interacts with the strategy contract.
     *      - **Gas rationale:** Performs minimal checks since rescue operations are rare and strictly governed.
     *      - **Event emission:** Emits {ERC20RescuedFromDualVault} for transparent off-chain accounting.
     *
     * @param _tokenAddress    ERC20 token address to recover.
     * @param _receiverAddress Recipient address (must be non-zero).
     * @param _amount          Amount to transfer.
     *
     * @custom:security Must only be used for non-core tokens inadvertently sent to the vault. Core asset recovery should
     *                  instead be performed through {emergencyExit()}.
     */
    function rescueERC20(address _tokenAddress, address _receiverAddress, uint256 _amount) external onlyUpgraderRole nonReentrant {
        if (_receiverAddress == address(0)) revert BirdieswapDualVaultV1__ZeroAddressNotAllowed();
        if (_amount == 0) revert BirdieswapDualVaultV1__InvalidAmount();

        if (_tokenAddress == i_bToken0Address || _tokenAddress == i_bToken1Address) revert BirdieswapDualVaultV1__CannotRescueBToken();
        if (_tokenAddress == address(this)) revert BirdieswapDualVaultV1__CannotRescueBLPToken();

        IERC20(_tokenAddress).safeTransfer(_receiverAddress, _amount);
        try i_event.emitERC20RescuedFromDualVault(_tokenAddress, _amount, _receiverAddress, msg.sender) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                      STANDARD ERC4626 ENTRYPOINTS
            (intentionally disabled for dual-asset design)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
    function mint(uint256 _shares, address _receiver) public override returns (uint256) {
        try i_event.emitMintNotSupported(msg.sender, _shares, _receiver) { } catch { }
        revert BirdieswapDualVaultV1__MintNotSupported(_shares, _receiver);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 _assets, address _receiver, address _owner) public override returns (uint256) {
        try i_event.emitWithdrawNotSupported(msg.sender, _assets, _receiver, _owner) { } catch { }
        revert BirdieswapDualVaultV1__WithdrawNotSupported(_assets, _receiver, _owner);
    }

    /// @inheritdoc ERC4626
    function deposit(uint256 _assets, address _receiver) public override returns (uint256) {
        try i_event.emitMustDepositTwoTokens(msg.sender, _assets, _receiver) { } catch { }
        revert BirdieswapDualVaultV1__MustDepositTwoTokens(_assets, _receiver);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 _shares, address _receiver, address _owner) public override returns (uint256) {
        try i_event.emitMustRedeemProperly(msg.sender, _shares, _receiver, _owner) { } catch { }
        revert BirdieswapDualVaultV1__MustRedeemProperly(_shares, _receiver, _owner);
    }

    /*//////////////////////////////////////////////////////////////
           USER-FACING DUAL TOKEN ENTRYPOINTS (deposit/redeem)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Performs a dual-asset deposit by pulling two bTokens from the caller, forwarding them to the active
     *         strategy, and minting vault shares (`blpToken`) equal to the *observed* increase in strategy liquidity
     *         (`postLiquidity − preLiquidity`).
     *
     * @dev Security & design notes:
     *      - **Reentrancy protection:** Uses both {nonReentrant} and `strategyCallLock` to block direct and
     *        cross-function reentrancy, including callbacks originating from the strategy contract.
     *      - **CEI pattern:** Shares are minted strictly from the measured state delta rather than trusting any
     *        liquidity amount returned by the strategy.
     *      - **Monotonicity check:** Reverts with {LiquidityDecreased} if `postLiquidity < preLiquidity`,
     *        preventing negative deltas.
     *      - **Gas rationale:** Read-through validations (e.g., strategy address, active flag) are
     *        minimized—these do not affect token custody and are intentionally omitted from some view-only paths
     *        to save gas.
     *      - **ERC-4626 divergence:** This dual-token interface intentionally reuses the `deposit` name for
     *        consistency but does not follow the single-asset ERC-4626 signature.
     *
     * @param _userAddress    Address attributed in the `DualDeposit` event for off-chain analytics
     *                        (can differ from `msg.sender` if called via router).
     * @param _bToken0Amount  Amount of bToken0 to deposit (must be > 0).
     * @param _bToken1Amount  Amount of bToken1 to deposit (must be > 0).
     *
     * @return mintedShares       Number of vault shares minted to `msg.sender`.
     * @return returnToken0Amount Unused bToken0 refunded to `msg.sender`
     *                            if the strategy did not consume the full amount.
     * @return returnToken1Amount Unused bToken1 refunded to `msg.sender`
     *                            if the strategy did not consume the full amount.
     *
     * @custom:integration Caller must approve this vault for both bTokens prior to calling.
     * @custom:security    Users SHOULD avoid unlimited approvals; frontends SHOULD request minimal allowances.
     */
    function deposit(address _userAddress, uint256 _bToken0Amount, uint256 _bToken1Amount)
        external
        nonReentrant
        strategyCallLock
        whenNotPaused
        whenStrategyActive
        returns (uint256, uint256, uint256)
    {
        if ((_bToken0Amount == 0) || (_bToken1Amount == 0)) revert BirdieswapDualVaultV1__ZeroAmountNotAllowed();
        IBirdieswapDualStrategyV1 strategy = IBirdieswapDualStrategyV1(s_strategyAddress);

        // ───────────── Record pre-deposit liquidity ──────────────
        uint256 preLiquidity = strategy.getPositionLiquidity();

        // ─────────────── Pull user funds into vault ──────────────
        // User transfers both bTokens to this vault; router or user may call directly.
        {
            address strategyAddress = address(strategy);
            IERC20 bToken0 = IERC20(i_bToken0Address);
            IERC20 bToken1 = IERC20(i_bToken1Address);

            // Pull in user's wrapped proof tokens (bToken0, bToken1)
            bToken0.safeTransferFrom(msg.sender, address(this), _bToken0Amount);
            bToken1.safeTransferFrom(msg.sender, address(this), _bToken1Amount);

            // Forward both tokens to the active strategy for processing.
            bToken0.safeTransfer(strategyAddress, _bToken0Amount);
            bToken1.safeTransfer(strategyAddress, _bToken1Amount);
        }

        // ─────────────── Trigger strategy deposit ────────────────
        // The strategy returns raw liquidity data, but we derive our own delta for accounting safety.
        uint256 preTotalSupply = totalSupply();
        uint256 mintedShares;
        uint256 returnToken0Amount;
        uint256 returnToken1Amount;

        {
            uint256 liquidity;
            (liquidity, returnToken0Amount, returnToken1Amount) = strategy.deposit(_bToken0Amount, _bToken1Amount);

            // ────── Post-deposit validation and accounting ───────
            uint256 postLiquidity = strategy.getPositionLiquidity();
            if (preLiquidity > postLiquidity) revert BirdieswapDualVaultV1__LiquidityDecreased();

            uint256 deltaLiquidity = postLiquidity - preLiquidity;
            if (deltaLiquidity == 0) revert BirdieswapDualVaultV1__NoLiquidityReceived();
            if (returnToken0Amount > _bToken0Amount || returnToken1Amount > _bToken1Amount) {
                revert BirdieswapDualVaultV1__InconsistentLiquidity();
            }

            // Calculate minted share amount based on observed liquidity delta.
            mintedShares =
                (preTotalSupply == 0 || preLiquidity == 0) ? deltaLiquidity : Math.mulDiv(deltaLiquidity, preTotalSupply, preLiquidity);

            if (mintedShares == 0) revert BirdieswapDualVaultV1__NoLiquidityReceived();
            if (!_isWithinTolerance(deltaLiquidity, liquidity, i_roundingTolerance)) revert BirdieswapDualVaultV1__InconsistentLiquidity();

            // Mint Birdieswap LP tokens (blpTokens) representing ownership in this vault.
            _mint(msg.sender, mintedShares);

            // ──────────── Post-mint consistency check ────────────
            unchecked {
                uint256 postTotalSupply = totalSupply();
                // Ensures minted amount matches actual total supply increase.
                if (postTotalSupply - preTotalSupply != mintedShares) revert BirdieswapDualVaultV1__InconsistentLiquidity();
            }
        }

        // ─────────────── Refund any unspent bTokens ──────────────
        {
            IERC20 bToken0 = IERC20(i_bToken0Address);
            IERC20 bToken1 = IERC20(i_bToken1Address);

            if (returnToken0Amount > 0) bToken0.safeTransfer(msg.sender, returnToken0Amount);
            if (returnToken1Amount > 0) bToken1.safeTransfer(msg.sender, returnToken1Amount);
        }

        // ──────────────── Emit dual deposit event ────────────────
        // address(this) represents both the vault contract and its issued token.
        try i_event.emitDualDeposit(
            _userAddress, i_bToken0Address, _bToken0Amount, i_bToken1Address, _bToken1Amount, address(this), mintedShares
        ) { } catch { }

        return (mintedShares, returnToken0Amount, returnToken1Amount);
    }

    /**
     * @notice Performs a dual-asset redemption by burning vault shares (`blpToken`) and withdrawing proportional
     *         amounts of both bTokens through the active strategy’s liquidity decrease.
     *
     * @dev Security & design notes:
     *      - **CEI pattern:** The burn occurs *before* any external call to the strategy, ensuring state
     *        consistency even if the strategy reverts.
     *      - **Reentrancy protection:** Combines {nonReentrant} with `strategyCallLock` to block direct and
     *        cross-function reentrancy, including callbacks from the strategy contract.
     *      - **Accounting correctness:** The amount of liquidity withdrawn from the strategy is computed as a
     *        proportional share of total liquidity (`preLiquidity * shares / totalSupply`), ensuring pro-rata
     *        redemption.
     *      - **Gas rationale:** Minimal redundant validation is performed, as share burning and liquidity math
     *        already enforce invariants; this saves gas without compromising safety.
     *      - **ERC-4626 divergence:** This dual-token interface intentionally reuses the `redeem` name but differs
     *        from the single-asset ERC-4626 signature and semantics.
     *
     * @param _caller         Address logged in the `DualWithdraw` event for attribution
     *                        (e.g., router or end-user).
     * @param _owner          Address whose shares are burned and who receives the output bTokens.
     * @param _blpTokenAmount Amount of shares to burn from `_owner`.
     *
     * @return bToken0Amount  Amount of bToken0 returned to `_owner`.
     * @return bToken1Amount  Amount of bToken1 returned to `_owner`.
     *
     * @custom:integration If `msg.sender != _owner`, the caller must hold allowance from `_owner`
     *                     for `_blpTokenAmount`. Users SHOULD keep allowances minimal.
     * @custom:note        Redemption returns the floor of the pro-rata amounts of both tokens.
     */
    function redeem(address _caller, address _owner, uint256 _blpTokenAmount)
        external
        nonReentrant
        strategyCallLock
        whenStrategyActive
        returns (uint256, uint256)
    {
        // ──────────── Authorization & allowance check ────────────
        // If called by someone other than the token owner, spend from their approved allowance.
        // Note: The share value of _blpTokenAmount increases over time as underlying liquidity compounds.
        // Hence, the redeemed amount reflects the appreciated value relative to total vault liquidity.
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _blpTokenAmount);

        // ────────── Fetch strategy and pre-redeem state ──────────
        IBirdieswapDualStrategyV1 strategy = IBirdieswapDualStrategyV1(s_strategyAddress);
        uint256 preTotalSupply = totalSupply();
        if (preTotalSupply == 0) revert BirdieswapDualVaultV1__NoSharesExist();

        uint256 preLiquidity = strategy.getPositionLiquidity();

        // Compute proportional share of total liquidity to withdraw.
        // adjustedShareAmount = currentLiquidity * userShares / totalSupply
        uint256 adjustedShareAmount = Math.mulDiv(preLiquidity, _blpTokenAmount, preTotalSupply);
        if (adjustedShareAmount == 0) revert BirdieswapDualVaultV1__NoLiquidityReceived();

        // ──────── Burn vault shares before external call ─────────
        // CEI pattern — state change (burn) before interacting with external contracts.
        _burn(_owner, _blpTokenAmount);

        // ──────────── Trigger redemption via strategy ────────────
        // The strategy withdraws proportional liquidity and returns redeemed token amounts.
        (uint256 bToken0Amount, uint256 bToken1Amount) = strategy.redeem(adjustedShareAmount);

        // ────────────── Post-redemption validation ───────────────
        uint256 postLiquidity = strategy.getPositionLiquidity();
        unchecked {
            // Ensure liquidity decreased exactly by adjustedShareAmount and supply decreased by _blpTokenAmount.
            if (postLiquidity > preLiquidity) revert BirdieswapDualVaultV1__InconsistentLiquidity();
            if (!_isWithinTolerance(preLiquidity - postLiquidity, adjustedShareAmount, i_roundingTolerance)) {
                revert BirdieswapDualVaultV1__InconsistentLiquidity();
            }
            if (preTotalSupply - totalSupply() != _blpTokenAmount) revert BirdieswapDualVaultV1__InconsistentLiquidity();
        }

        // ────────── Transfer redeemed assets to owner ────────────
        IERC20 bToken0 = IERC20(i_bToken0Address);
        IERC20 bToken1 = IERC20(i_bToken1Address);
        bToken0.safeTransfer(_owner, bToken0Amount);
        bToken1.safeTransfer(_owner, bToken1Amount);

        // ────────────── Emit dual withdrawal event ───────────────
        try i_event.emitDualWithdraw(
            _caller, address(this), _blpTokenAmount, i_bToken0Address, bToken0Amount, i_bToken1Address, bToken1Amount
        ) { } catch { }

        return (bToken0Amount, bToken1Amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current Uniswap V3 position liquidity reported by the active strategy.
     *
     * @dev Performs a safety check to ensure the reported value fits within `uint128`, Uniswap’s native liquidity type.
     *      Used in accounting and ERC4626 compliance views to guarantee that liquidity values remain within supported
     *      on-chain bounds.
     *
     * @dev Security rationale:
     *      - **Upper bound check:** Uniswap core defines liquidity as `uint128`; reverts if reported value exceeds range.
     *      - **Trust assumption:** Strategy is expected to return accurate data, but this guard prevents silent overflow
     *        that could compromise share accounting.
     *      - **Non-mutating:** Pure view call with no reentrancy or state modification.
     *
     * @return liquidity  Current position liquidity safely truncated to uint128.
     */
    function _strategyLiquidity() private view returns (uint128) {
        uint256 liquidity = IBirdieswapDualStrategyV1(s_strategyAddress).getPositionLiquidity();
        if (liquidity > type(uint128).max) revert BirdieswapDualVaultV1__LiquidityOverflow();

        return uint128(liquidity);
    }

    /**
     * @notice Validates a proposed strategy before registration as pending or active.
     * @dev    Ensures that the new strategy is correctly bound to this vault, uses proper assets, and references a valid
     *         Uniswap pool.
     *
     * @dev Called during both {proposeStrategy()} and {acceptStrategy()}. Validation failures trigger {_failValidation()}
     *      and emit a descriptive {DualStrategyValidationFailed} event.
     *
     * @dev Validation sequence:
     *      1. Rejects zero address or reuse of the current strategy.
     *      2. Confirms bytecode existence via `extcodesize()` (contract check).
     *      3. Validates bidirectional vault linkage via {getDualVaultAddress()}.
     *      4. Checks asset consistency via {getPositionComposition()} against immutable bToken pair.
     *      5. Ensures a valid, non-zero pool address via {getPoolAddress()}.
     *
     * @dev Security rationale:
     *      - **Governance safety:** Prevents invalid or malicious strategy attachment that could break accounting or custody.
     *      - **Fail-fast:** Each validation step isolates specific failure causes via try/catch for explicit event reporting.
     *      - **Gas:** Slightly heavier but only called rarely by governance, not during user operations.
     *
     * @param _newStrategy  Address of the strategy candidate to validate.
     * @return isValid      Returns true if all checks pass; otherwise reverts via {_failValidation()}.
     */
    function _validateStrategy(address _newStrategy) internal returns (bool) {
        if (_newStrategy == address(0)) _failValidation(_newStrategy, DualStrategyValidationReason.ZERO_ADDRESS);
        if (_newStrategy == s_strategyAddress) _failValidation(_newStrategy, DualStrategyValidationReason.SAME_AS_EXISTING);

        uint32 size;
        assembly {
            size := extcodesize(_newStrategy)
        }
        if (size == 0) _failValidation(_newStrategy, DualStrategyValidationReason.NOT_CONTRACT);

        IBirdieswapDualStrategyV1 strategy = IBirdieswapDualStrategyV1(_newStrategy);

        // ─────────────── Vault linkage validation ────────────────
        try strategy.getDualVaultAddress() returns (address vaultAddress) {
            if (vaultAddress != address(this)) _failValidation(_newStrategy, DualStrategyValidationReason.VAULT_MISMATCH);
        } catch {
            _failValidation(_newStrategy, DualStrategyValidationReason.VAULT_MISMATCH);
        }

        // ───────────── Asset consistency validation ──────────────
        try strategy.getPositionComposition() returns (address t0, address t1, uint256, uint256) {
            if (t0 != i_bToken0Address || t1 != i_bToken1Address) {
                _failValidation(_newStrategy, DualStrategyValidationReason.ASSET_MISMATCH);
            }
        } catch {
            _failValidation(_newStrategy, DualStrategyValidationReason.ASSET_MISMATCH);
        }

        // ──────────────── Pool address validation ────────────────
        try strategy.getPoolAddress() returns (address pool) {
            if (pool == address(0)) _failValidation(_newStrategy, DualStrategyValidationReason.INVALID_POOL_ADDRESS);
        } catch {
            _failValidation(_newStrategy, DualStrategyValidationReason.INVALID_POOL_ADDRESS);
        }

        return true;
    }

    /**
     * @notice Handles validation failures by emitting a descriptive event and reverting deterministically.
     *
     * @dev Used exclusively by {_validateStrategy()} to provide structured feedback without revert strings,
     *      preserving gas efficiency and explicit error typing.
     *
     * @param _newStrategy  Address of the strategy candidate that failed validation.
     * @param _reason       Enumerated {DualStrategyValidationReason} indicating which validation step failed.
     *
     * @custom:security Always reverts before any state changes occur, ensuring atomicity and preventing partial
     *                  configuration of untrusted strategies.
     */
    function _failValidation(address _newStrategy, DualStrategyValidationReason _reason) private {
        try i_event.emitDualStrategyValidationFailed(_newStrategy, uint8(_reason)) { } catch { }
        revert BirdieswapDualVaultV1__InvalidStrategy();
    }

    /// @dev Returns true if `a` and `b` differ by no more than `tolerance` wei.
    function _isWithinTolerance(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        return a > b ? a - b <= tolerance : b - a <= tolerance;
    }
}
/*//////////////////////////////////////////////////////////////
                        END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant Dual-asset immutability — the vault permanently operates on exactly two immutable bTokens (i_bToken0Address,
///                   i_bToken1Address), with ordering fixed at construction.
/// @custom:invariant NFT custody & delegation — the Uniswap position NFT is always owned by the vault; only the currently active strategy
///                   holds approval for that specific tokenId (no transfer of ownership).
/// @custom:invariant Reentrancy & pause safety — all user flows are guarded by {nonReentrant} and {strategyCallLock}; when paused, deposits
///                   are disabled while redemptions remain available.
/// @custom:invariant Accounting soundness — share mint/burn amounts are derived from the observed strategy-liquidity delta (post − pre);
///                   redemptions pay out strictly pro-rata to total supply via {Math.mulDiv}.
