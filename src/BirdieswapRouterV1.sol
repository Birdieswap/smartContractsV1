// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
    - OpenZeppelin v5.4.0 upgradeable building blocks and SafeERC20
    - Uniswap v3 periphery interfaces (v1.4.4)
    - Birdieswap vault contracts and shared storage
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils } from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

// Uniswap V3 interface imports (v3-periphery v1.4.4)
import { IV3SwapRouter, ISwapRouter02 } from "./interfaces/ISwapRouter02.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "./BirdieswapConfigV1.sol";
import { BirdieswapDualVaultV1 } from "./BirdieswapDualVaultV1.sol";
import { BirdieswapRoleSignaturesV1 } from "./BirdieswapRoleSignaturesV1.sol";
import { BirdieswapSingleVaultV1 } from "./BirdieswapSingleVaultV1.sol";
import { BirdieswapStorageV1 } from "./BirdieswapStorageV1.sol";
import { IBirdieswapDualVaultV1 } from "./interfaces/IBirdieswapDualVaultV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapRoleRouterV1 } from "./interfaces/IBirdieswapRoleRouterV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapRouterV1
 * @author Birdieswap Team
 * @notice Core entry point for all user-facing operations — deposits, redemptions, and swaps — across the Birdieswap vault ecosystem.
 * @dev    UUPS-upgradeable. Vaults and strategies are non-upgradeable; governance may update router mappings to point to different
 *         deployed vaults/strategies (no code mutation).
 *
 * ───────────────────────────────────────────────────────────────
 *                          ARCHITECTURE
 * ───────────────────────────────────────────────────────────────
 *  - **BirdieswapWrapper** (auxiliary on-chain wrapper): non-upgradeable and replaceable.
 *  - **BirdieswapRouterV1** (this contract): upgradeable via UUPS pattern.
 *  - **Single Vault (bToken)**: ERC4626-compliant vault holding one vanilla token.
 *  - **Single Strategy**: non-upgradeable strategy contract managed by a single vault.
 *  - **Dual Vault (blpToken)**: ERC4626-compliant vault managing a pair of bTokens.
 *  - **Dual Strategy**: non-upgradeable strategy paired with a dual vault.
 *
 * Each vault and strategy pair is isolated and stateless across upgrades. The router acts as a coordination layer connecting vaults,
 * strategies, the event relayer, and global configuration.
 *
 * ───────────────────────────────────────────────────────────────
 *                      TOKEN MODEL & TERMINOLOGY
 * ───────────────────────────────────────────────────────────────
 *  - Each **Single Vault** issues its own ERC20 share token called a **bToken**.
 *    The vault address itself doubles as the bToken contract address.
 *
 *  - Each **Dual Vault** issues an ERC20 LP share token called a **blpToken**.
 *    Similarly, the dual vault address doubles as the blpToken contract address.
 *
 *  - For ERC4626 compliance:
 *      * `asset()` on a single vault returns the vault’s **proof token** (the token it actually holds within an external protocol).
 *      * `underlyingToken()` is an additional Birdieswap extension exposing the final **vanilla underlying token** recognizable by
 *        end-users. Therefore, `asset()` (proof token) and `underlyingToken()` (vanilla token) may intentionally differ.
 *
 * ───────────────────────────────────────────────────────────────
 *                           GOVERNANCE
 * ───────────────────────────────────────────────────────────────
 *  - Access control and role management are delegated to `BirdieswapRoleRouterV1`.
 *  - Configuration constants and global addresses are sourced from `BirdieswapConfigV1`.
 *  - Authorized roles:
 *      * `DEFAULT_ADMIN_ROLE` — full governance authority.
 *      * `GUARDIAN_ROLE` / `GUARDIAN_FULL_ROLE` — emergency controls (pause/unpause).
 *      * `UPGRADER_ROLE` — authorized to execute UUPS upgrades.
 *
 * ───────────────────────────────────────────────────────────────
 *                             ASSUMPTIONS
 * ───────────────────────────────────────────────────────────────
 *  - All vaults registered through this router are trusted and verified within the protocol boundary.
 *  - Only standard ERC20 tokens are supported (no fee-on-transfer or rebasing).
 *  - Deposits, swaps, and redemptions use the ERC4626 **push model**:
 *        Router pulls assets → deposits into vaults → pushes resulting shares back.
 *  - The router rejects any incoming ERC721 transfers through `onERC721Received`.
 *
 * ───────────────────────────────────────────────────────────────
 *                             SUMMARY
 * ───────────────────────────────────────────────────────────────
 *  BirdieswapRouterV1 acts as the single unified gateway between user-facing operations and underlying vault logic, ensuring consistent
 *  access control, safe token handling, and standardized event propagation across the protocol’s modules.
 */
contract BirdieswapRouterV1 is
    Initializable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    BirdieswapRoleSignaturesV1
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    // ────────────────────── Access Control ───────────────────────
    error BirdieswapRouterV1__UnauthorizedAccess(); // Caller lacks required role or permission.

    // ─────────────────────── Pause-related ───────────────────────
    error BirdieswapRouterV1__DepositsAlreadyPaused(); // Deposits are already paused.
    error BirdieswapRouterV1__DepositsNotPaused(); // Deposits are not paused.
    error BirdieswapRouterV1__DepositsPaused(); // Action requires deposits-enabled but they are paused.
    error BirdieswapRouterV1__SwapsAlreadyPaused(); // Swaps are already paused.
    error BirdieswapRouterV1__SwapsNotPaused(); // Swaps are not paused.
    error BirdieswapRouterV1__SwapsPaused(); // Swaps are paused.

    // ─────────────────── Parameter Validation ────────────────────
    error BirdieswapRouterV1__InvalidAddress(); // Zero address or invalid parameter.
    error BirdieswapRouterV1__InvalidAmount(); // Zero or otherwise invalid amount.
    error BirdieswapRouterV1__InvalidMapping(); // Mapping inputs do not match vault invariants.
    error BirdieswapRouterV1__InvalidSwapParameters(); // Swap parameters are inconsistent/invalid.

    // ─────────────────── Registry / Lookups ──────────────────────
    error BirdieswapRouterV1__SingleVaultNotFound(); // Single vault not found for given token.
    error BirdieswapRouterV1__UnderlyingTokenNotFound(); // Underlying token not found for given vault.
    error BirdieswapRouterV1__DualVaultNotFound(); // Dual vault not found for given bToken pair.

    // ───────────────────── Token Accounting ──────────────────────
    error BirdieswapRouterV1__InsufficientBalance(); // Caller’s balance is insufficient.
    error BirdieswapRouterV1__ApprovalNeeded(); // Caller has not granted sufficient allowance to the router.

    // ────────────────────────── Swap ─────────────────────────────
    error BirdieswapRouterV1__MinimumAmountNetReceived(); // Swap result does not meet the minimum output amount.

    // ─────────────────────── Miscellaneous ────────────────────────
    /// @notice Router rejects NFT custody via safe transfer hooks.
    error BirdieswapRouterV1__NotAllowedNFT(address, address, uint256, bytes);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── Version ──────────────────────────
    /// @notice Contract version identifier.
    string internal constant CONTRACT_VERSION = "BirdieswapRouterV1";

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES 
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Core Contracts ───────────────────────
    /// @notice Protocol configuration (global constants, roles, addresses).
    BirdieswapConfigV1 private s_config;

    /// @notice Centralized storage module (protocol-wide state container).
    BirdieswapStorageV1 private s_storage;

    /// @notice Role router contract (global access control hub).
    IBirdieswapRoleRouterV1 private s_role;

    /// @notice Event relayer contract (centralized event emitter).
    IBirdieswapEventRelayerV1 private s_event;

    // ─────────────────────── System Flags ────────────────────────
    /**
     * @notice Indicates whether deposits are paused (true) or allowed (false).
     * @dev This flag only controls deposit-related functions. Full protocol pause is managed separately by `PausableUpgradeable`.
     */
    bool internal _depositsPaused;

    /**
     * @notice Indicates whether swaps are globally paused (true) or allowed (false).
     * @dev This flag only controls swap-related functions. Full protocol pause is managed separately by `PausableUpgradeable`.
     */
    bool internal _swapsPaused;

    /*//////////////////////////////////////////////////////////////
                           UPGRADEABLE GAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Reserved storage space to allow layout changes in future upgrades. New variables must be added above this line. This gap ensures
     *      that upgrading the contract will not cause storage collisions.
     */
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the router module and links all core Birdieswap dependencies.
     * @dev    Can only be called once. Validates nonzero addresses and deployed code presence for each dependency before assignment.
     * @param  storageAddress_      Address of the BirdieswapStorageV1 contract.
     * @param  roleRouterAddress_   Address of the BirdieswapRoleRouterV1 contract.
     * @param  eventRelayerAddress_ Address of the BirdieswapEventRelayerV1 contract.
     */
    function initialize(address storageAddress_, address roleRouterAddress_, address eventRelayerAddress_) public initializer {
        // ─────────────────── Input Validation ────────────────────
        if (storageAddress_ == address(0) || roleRouterAddress_ == address(0) || eventRelayerAddress_ == address(0)) {
            revert BirdieswapRouterV1__InvalidAddress();
        }
        if (storageAddress_.code.length == 0 || roleRouterAddress_.code.length == 0 || eventRelayerAddress_.code.length == 0) {
            revert BirdieswapRouterV1__InvalidAddress();
        }

        // ──────────────── Core Dependency Linkage ────────────────
        s_storage = BirdieswapStorageV1(storageAddress_);
        s_role = IBirdieswapRoleRouterV1(roleRouterAddress_);
        s_event = IBirdieswapEventRelayerV1(eventRelayerAddress_);

        // ───────────── Initialize Inherited Modules ──────────────
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @dev UUPS authorization hook.
    ///      Restricts upgrades to callers with UPGRADER_ROLE (via onlyUpgraderRole).
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgraderRole {
        // Emit event for governance transparency
        try s_event.emitRouterUpgraded(ERC1967Utils.getImplementation(), newImplementation, _msgSender()) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS & MODIFIERS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Pause Modifiers ──────────────────────
    /// @notice Reverts if deposits are currently paused.
    modifier whenDepositsActive() {
        if (_depositsPaused) revert BirdieswapRouterV1__DepositsPaused();
        _;
    }

    /// @notice Reverts if swaps are currently paused.
    modifier whenSwapsActive() {
        if (_swapsPaused) revert BirdieswapRouterV1__SwapsPaused();
        _;
    }

    // ─────────────────── Role-based Modifiers ────────────────────
    /// @notice Restricts execution to Upgrader role.
    modifier onlyUpgraderRole() {
        if (!s_role.hasRoleGlobal(UPGRADER_ROLE, _msgSender())) revert BirdieswapRouterV1__UnauthorizedAccess();
        _;
    }

    /// @notice Restricts execution to Unpauser role.
    modifier onlyUnpauserRole() {
        if (!s_role.hasRoleGlobal(UNPAUSER_ROLE, _msgSender())) revert BirdieswapRouterV1__UnauthorizedAccess();
        _;
    }

    /// @notice Restricts execution to Default Admin role.
    modifier onlyDefaultAdminRole() {
        if (!s_role.hasRoleGlobal(DEFAULT_ADMIN_ROLE, _msgSender())) revert BirdieswapRouterV1__UnauthorizedAccess();
        _;
    }

    /// @notice Restricts execution to GuardianFull role.
    modifier onlyGuardianFullRole() {
        if (!s_role.hasRoleGlobal(GUARDIAN_FULL_ROLE, _msgSender())) revert BirdieswapRouterV1__UnauthorizedAccess();
        _;
    }

    /// @notice Restricts execution to Guardian or GuardianFull roles.
    modifier onlyGuardianRole() {
        if (!(s_role.hasRoleGlobal(GUARDIAN_ROLE, _msgSender()) || s_role.hasRoleGlobal(GUARDIAN_FULL_ROLE, _msgSender()))) {
            revert BirdieswapRouterV1__UnauthorizedAccess();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSING LOGIC
    - Global pause: blocks all state-changing functions.
    - Deposit pause: blocks deposits and swaps (swaps require deposits).
    - Swap pause: blocks swaps only.
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Global Pause ────────────────────────
    /// @notice Globally pauses all state-changing protocol functions.
    function pause() external onlyGuardianFullRole {
        _pause();
        try s_event.emitGlobalPaused(_msgSender()) { } catch { }
    }

    /// @notice Lifts the global pause, resuming normal operation.
    function unpause() external onlyUnpauserRole {
        _unpause();
        try s_event.emitGlobalUnpaused(_msgSender()) { } catch { }
    }

    // ─────────────────────── Deposit Pause ───────────────────────
    /// @notice Pauses deposit-related functions (also disables swaps).
    function pauseDeposits() external onlyGuardianRole {
        if (_depositsPaused) revert BirdieswapRouterV1__DepositsAlreadyPaused();
        _depositsPaused = true;
        try s_event.emitDepositsPaused(_msgSender()) { } catch { }
    }

    /// @notice Unpauses deposit-related functions (also re-enables swaps).
    function unpauseDeposits() external onlyUnpauserRole {
        if (!_depositsPaused) revert BirdieswapRouterV1__DepositsNotPaused();
        _depositsPaused = false;
        try s_event.emitDepositsUnpaused(_msgSender()) { } catch { }
    }

    /// @notice Returns whether deposits are currently paused.
    function depositsPaused() external view returns (bool) {
        return _depositsPaused;
    }

    // ──────────────────────── Swap Pause ─────────────────────────
    /// @notice Pauses all swap-related operations.
    function pauseSwaps() external onlyGuardianFullRole {
        if (_swapsPaused) revert BirdieswapRouterV1__SwapsAlreadyPaused();
        _swapsPaused = true;
        try s_event.emitSwapsPaused(_msgSender()) { } catch { }
    }

    /// @notice Unpauses all swap-related operations.
    function unpauseSwaps() external onlyUnpauserRole {
        if (!_swapsPaused) revert BirdieswapRouterV1__SwapsNotPaused();
        _swapsPaused = false;
        try s_event.emitSwapsUnpaused(_msgSender()) { } catch { }
    }

    /// @notice Returns whether swaps are currently paused.
    function swapsPaused() external view returns (bool) {
        return _swapsPaused;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW GETTERS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── System Metadata ──────────────────────
    /// @notice Returns the router contract version string.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /// @notice Returns the current implementation address (UUPS context).
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    // ──────────────── Single Vault (bToken) State ────────────────
    /// @notice Returns the total assets (proof tokens) currently managed by a single vault (bToken).
    function totalAssets(address _bTokenAddress) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_bTokenAddress).totalAssets();
    }

    /// @notice Returns the total bToken supply of a single vault.
    function totalSupply(address _bTokenAddress) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_bTokenAddress).totalSupply();
    }

    /// @notice Returns the total balance of vanilla underlying tokens represented by a single vault.
    function totalUnderlyingBalance(address _bTokenAddress) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_bTokenAddress).totalUnderlyingBalance();
    }

    /// @notice Returns aggregate vault metrics: totalAssets, totalSupply, and totalUnderlyingBalance.
    /// @dev Convenience getter combining three core single-vault state variables into one call.
    function getVaultState(address _bTokenAddress) external view returns (uint256, uint256, uint256) {
        BirdieswapSingleVaultV1 singleVault = BirdieswapSingleVaultV1(_bTokenAddress);
        return (singleVault.totalAssets(), singleVault.totalSupply(), singleVault.totalUnderlyingBalance());
    }

    // ──────────────── Dual Vault (blpToken) State ────────────────
    /// @notice Returns the total assets currently managed by a dual vault (blpToken).
    function totalDualAssets(address _blpTokenAddress) external view returns (uint256) {
        return BirdieswapDualVaultV1(_blpTokenAddress).totalAssets();
    }

    /// @notice Returns the total supply of a dual vault’s liquidity tokens (blpToken).
    function totalDualSupply(address _blpTokenAddress) external view returns (uint256) {
        return BirdieswapDualVaultV1(_blpTokenAddress).totalSupply();
    }

    /// @notice Returns underlying token addresses and amounts represented within a dual vault.
    /// @dev Internally derives each underlying token’s amount via single-vault redemption previews. Amounts are computed via
    ///      previewFullRedeem and may differ slightly from post-redeem amounts if exchange rates change intra-block.
    function totalDualUnderlyingTokens(address _blpTokenAddress) external view returns (address, address, uint256, uint256) {
        (address bToken0, address bToken1, uint256 amt0, uint256 amt1) = BirdieswapDualVaultV1(_blpTokenAddress).totalBTokens();

        BirdieswapSingleVaultV1 v0 = BirdieswapSingleVaultV1(bToken0);
        BirdieswapSingleVaultV1 v1 = BirdieswapSingleVaultV1(bToken1);

        return (
            _getUnderlyingTokenAddress(bToken0), _getUnderlyingTokenAddress(bToken1), v0.previewFullRedeem(amt0), v1.previewFullRedeem(amt1)
        );
    }

    // ────────────────────── Mapping Lookups ──────────────────────
    /// @notice Returns the single vault (bToken) mapped to a given vanilla underlying token.
    function getBTokenAddress(address _underlyingTokenAddress) external view returns (address) {
        return _getBTokenAddress(_underlyingTokenAddress);
    }

    /// @notice Returns the vanilla underlying token mapped to a given single vault (bToken) address.
    function getUnderlyingTokenAddress(address _bTokenAddress) external view returns (address) {
        return _getUnderlyingTokenAddress(_bTokenAddress);
    }

    /// @notice Returns the dual vault (blpToken) corresponding to an unordered pair of bTokens.
    /// @dev Internally normalizes the pair to ordered form (min, max) before lookup.
    function getBLPTokenAddress(address _bToken0Address, address _bToken1Address) external view returns (address) {
        return _getBLPTokenAddress(_bToken0Address, _bToken1Address);
    }

    /// @notice Returns the ordered (bToken0, bToken1) pair behind a given dual vault (blpToken) address.
    function getBTokenPair(address _blpTokenAddress) external view returns (address, address) {
        return s_storage.blpTokenToBTokenPair(_blpTokenAddress);
    }

    /**
     * @notice Checks if a given unordered (bToken0, bToken1) pair matches the canonical dual-vault ordering.
     * @dev Returns true if pair matches stored (bToken0, bToken1), false if reversed, and reverts if no mapping exists.
     */
    function isBToken0First(address _bToken0Address, address _bToken1Address) external view returns (bool) {
        address blpTokenAddress = s_storage.getBLPTokenAddress(_bToken0Address, _bToken1Address);
        if (blpTokenAddress == address(0)) revert BirdieswapRouterV1__InvalidMapping();

        (address b0, address b1) = s_storage.blpTokenToBTokenPair(blpTokenAddress);
        if ((_bToken0Address == b0) && (_bToken1Address == b1)) return true;
        if ((_bToken0Address == b1) && (_bToken1Address == b0)) return false;

        revert BirdieswapRouterV1__InvalidMapping();
    }

    // ───────────────────── Preview Functions ─────────────────────
    /// @notice Previews the number of bTokens minted for depositing a given amount of vanilla underlying.
    function previewFullDeposit(address _vault, uint256 _underlyingTokenAmount) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_vault).previewFullDeposit(_underlyingTokenAmount);
    }

    /// @notice Previews the required underlying token amount to mint a specified amount of bTokens.
    function previewFullMint(address _vault, uint256 _bTokenAmount) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_vault).previewFullMint(_bTokenAmount);
    }

    /// @notice Previews the amount of vanilla underlying obtained by redeeming a given amount of bTokens.
    function previewFullRedeem(address _vault, uint256 _bTokenAmount) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_vault).previewFullRedeem(_bTokenAmount);
    }

    /// @notice Previews the number of bTokens burned for withdrawing a given amount of vanilla underlying.
    function previewFullWithdraw(address _vault, uint256 _underlyingTokenAmount) external view returns (uint256) {
        return BirdieswapSingleVaultV1(_vault).previewFullWithdraw(_underlyingTokenAmount);
    }

    /// @notice Returns the ERC4626 `asset()` (proof token) of a single vault.
    /// @dev Birdieswap distinguishes between proof tokens (`asset()`) and vanilla tokens (`underlyingToken()`).
    function asset(address _vault) external view returns (address) {
        return BirdieswapSingleVaultV1(_vault).asset();
    }

    /// @notice Returns the Uniswap V3 fee tier configured within a given dual vault.
    /// @dev Reads the stored pool fee tier from the corresponding dual vault contract.
    function getFeeTier(address _blpTokenAddress) external view returns (uint24) {
        return IBirdieswapDualVaultV1(_blpTokenAddress).getFeeTier();
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE / MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Registers or updates the mapping between a vanilla underlying token and its corresponding single vault (bToken).
     * @dev Enforces bijective consistency between `underlyingToBToken` and `bTokenToUnderlying` mappings, and validates vault integrity.
     *
     * Emits: SingleVaultMappingSet(_underlyingTokenAddress, _bTokenAddressOld, _bTokenAddressNew);
     *  - calls relayer's {emitSingleVaultMappingSet} when a mapping is newly created or updated.
     *    (No event is emitted if the existing mapping is identical.)
     *
     * Reverts:
     *  - {BirdieswapRouterV1__InvalidMapping} if parameters are invalid,
     *    inconsistent, or refer to non-vault contracts.
     */
    function setSingleVaultMapping(address _underlyingTokenAddress, address _bTokenAddress) external onlyDefaultAdminRole {
        // ───────────────── Structural Validation ─────────────────
        {
            bool hasNoCode = (_underlyingTokenAddress.code.length == 0 || _bTokenAddress.code.length == 0);
            bool hasZero = (_underlyingTokenAddress == address(0) || _bTokenAddress == address(0));
            bool isSame = (_underlyingTokenAddress == _bTokenAddress);
            if (hasZero || hasNoCode || isSame) revert BirdieswapRouterV1__InvalidMapping();

            BirdieswapSingleVaultV1 bToken = BirdieswapSingleVaultV1(_bTokenAddress);

            // Ensure the vault's declared underlying token matches expectation.
            if (bToken.underlyingToken() != _underlyingTokenAddress) revert BirdieswapRouterV1__InvalidMapping();

            // Sanity check: vault must support a positive preview deposit.
            if (!(bToken.previewFullDeposit(1) > 0)) revert BirdieswapRouterV1__InvalidMapping();
        }

        // ───────────── Cross-check Existing Mappings ─────────────
        address oldVaultAddress = s_storage.underlyingToBToken(_underlyingTokenAddress);
        address oldUnderlyingTokenAddress = s_storage.bTokenToUnderlying(_bTokenAddress);

        // Allow mapping only if entries are vacant or already consistent.
        {
            bool underlyingVacantOrConsistent = (oldVaultAddress == address(0) || oldVaultAddress == _bTokenAddress);
            bool bTokenVacantOrConsistent =
                (oldUnderlyingTokenAddress == address(0) || oldUnderlyingTokenAddress == _underlyingTokenAddress);

            if (!(underlyingVacantOrConsistent && bTokenVacantOrConsistent)) revert BirdieswapRouterV1__InvalidMapping();
        }

        // ─────────── Mapping Update (Governance-Controlled) ───────────
        s_storage.setUnderlyingToBToken(_underlyingTokenAddress, _bTokenAddress);
        s_storage.setBTokenToUnderlying(_bTokenAddress, _underlyingTokenAddress);

        // Emit event only if mapping actually changed.
        if (oldVaultAddress != _bTokenAddress || oldUnderlyingTokenAddress != _underlyingTokenAddress) {
            try s_event.emitSingleVaultMappingSet(_underlyingTokenAddress, oldVaultAddress, _bTokenAddress) { } catch { }
        }
    }

    /**
     * @notice Registers or updates the mapping between an ordered pair of bTokens (bToken0 < bToken1) and its corresponding blpToken.
     * @dev Enforces ordered pair invariants and bijective consistency between `bTokenPairToBLPToken` and `blpTokenToBTokenPair` mappings.
     *
     * Emits: DualVaultMappingSet(_bToken0Address, _bToken1Address, _blpTokenAddressOld, _blpTokenAddressNew);
     *  - calls relayer's {emitDualVaultMappingSet} on successful creation or update.
     *
     * Reverts:
     *  - {BirdieswapRouterV1__InvalidMapping} if parameters are invalid or inconsistent.
     */
    function setDualVaultMapping(address _bToken0Address, address _bToken1Address, address _blpTokenAddress)
        external
        onlyDefaultAdminRole
    {
        // Validate that all addresses and structural relationships are correct.
        _validateDualVaultMapping(_bToken0Address, _bToken1Address, _blpTokenAddress);

        // ──────────────── Ordered Pair Resolution ────────────────
        (address token0Address, address token1Address) = _orderAddresses(_bToken0Address, _bToken1Address);

        // ─────── Consistency Checks (Vacant or Consistent) ───────
        address existingBLPTokenAddress = s_storage.getBLPTokenAddress(token0Address, token1Address);
        (address b0, address b1) = s_storage.blpTokenToBTokenPair(_blpTokenAddress);

        bool pairVacantOrConsistent = (existingBLPTokenAddress == address(0) || existingBLPTokenAddress == _blpTokenAddress);
        bool blpVacantOrConsistent = ((b0 == address(0) && b1 == address(0)) || (b0 == token0Address && b1 == token1Address));

        if (!(pairVacantOrConsistent && blpVacantOrConsistent)) revert BirdieswapRouterV1__InvalidMapping();

        // ───────── Mapping Update (Governance-Controlled) ─────────
        s_storage.setBLPMapping(_blpTokenAddress, token0Address, token1Address);

        // Emit event only when mapping is new or changed.
        if (existingBLPTokenAddress != _blpTokenAddress) {
            try s_event.emitDualVaultMappingSet(token0Address, token1Address, existingBLPTokenAddress, _blpTokenAddress) { } catch { }
        }
    }

    /**
     * @notice Whitelists or removes a reward token from the protocol.
     * @dev Used by governance to control which reward tokens are eligible for distribution.
     * @custom:governance Only callable by `DEFAULT_ADMIN_ROLE`.
     * @custom:security Prevents accidental activation of zero-address tokens.
     *
     * Emits: RewardTokenWhitelistSet(tokenAddress, allowed, byAddress);
     *  - calls relayer's {emitRewardTokenWhitelistSet} on status change.
     *
     * Reverts:
     *  - {BirdieswapRouterV1__InvalidAddress} if `_tokenAddress` is zero.
     */
    function setRewardTokenWhitelist(address _tokenAddress, bool _allowed) external onlyDefaultAdminRole {
        if (_tokenAddress == address(0)) revert BirdieswapRouterV1__InvalidAddress();

        s_storage.setRewardTokenWhitelist(_tokenAddress, _allowed);
        try s_event.emitRewardTokenWhitelistSet(_tokenAddress, _allowed, _msgSender()) { } catch { }
    }

    /**
     * @notice Registers or deregisters a contract as an official Birdieswap module.
     * @dev Used by governance to maintain the allowlist of protocol-recognized contracts.
     *
     * Emits: BirdieswapContractListSet(contractAddress, isTrue, byAddress)
     *  - calls relayer's {emitBirdieswapContractListSet} when a contract is added or removed.
     *
     * Reverts:
     *  - {BirdieswapRouterV1__InvalidAddress} if `_contractAddress` is zero.
     */
    function setBirdieswapContract(address _contractAddress, bool _isTrue) external onlyDefaultAdminRole {
        if (_contractAddress == address(0)) revert BirdieswapRouterV1__InvalidAddress();

        s_storage.setBirdieswapContract(_contractAddress, _isTrue);
        try s_event.emitBirdieswapContractListSet(_contractAddress, _isTrue, _msgSender()) { } catch { }
    }

    /**
     * @notice Updates the Event Relayer contract reference.
     * @dev Keeps the router and storage modules synchronized with the active relayer address.
     *
     * Emits: BirdieswapEventRelayerContractSet(contractAddress, byAddress);
     *  - calls relayer's {emitBirdieswapEventRelayerAddressSet} upon successful update.
     *
     * Reverts:
     *  - {BirdieswapRouterV1__InvalidAddress} if `_contractAddress` is zero.
     */
    function setEventRelayerAddress(address _contractAddress) external onlyDefaultAdminRole {
        if (_contractAddress == address(0)) revert BirdieswapRouterV1__InvalidAddress();

        s_storage.setEventRelayerAddress(_contractAddress);
        s_event = IBirdieswapEventRelayerV1(_contractAddress); // Keep router in sync
        try s_event.emitBirdieswapEventRelayerAddressSet(_contractAddress, _msgSender()) { } catch { }
    }

    function setRoleRouterAddress(address _contractAddress) external onlyDefaultAdminRole {
        if (_contractAddress == address(0)) revert BirdieswapRouterV1__InvalidAddress();

        s_storage.setRoleRouterAddress(_contractAddress);
        s_role = IBirdieswapRoleRouterV1(_contractAddress); // Keep router in sync
        try s_event.emitBirdieswapRoleRouterAddressSet(_contractAddress, _msgSender()) { } catch { }
    }

    function setFeeCollectingAddress(address _address) external onlyDefaultAdminRole {
        if (_address == address(0)) revert BirdieswapRouterV1__InvalidAddress();

        s_storage.setFeeCollectingAddress(_address);
        try s_event.emitBirdieswapFeeCollectingAddressSet(_address, _msgSender()) { } catch { }
    }

    function setRouterAddress(address _address) external onlyDefaultAdminRole {
        if (_address == address(0)) revert BirdieswapRouterV1__InvalidAddress();
        address oldAddress = ERC1967Utils.getImplementation();

        s_storage.setRouterAddress(oldAddress);
        try s_event.emitRouterUpgraded(oldAddress, _address, _msgSender()) { } catch { }
    }

    function setRouterConfigAddress(address _address) external onlyDefaultAdminRole {
        if (_address == address(0)) revert BirdieswapRouterV1__InvalidAddress();
        s_config = BirdieswapConfigV1(_address);

        try s_event.emitRouterConfigAddressSet(_address, _msgSender()) { } catch { }
    }
    /*//////////////////////////////////////////////////////////////
                    USER OPERATIONS: DEPOSIT / REDEEM / SWAP
        ------------------------------------------------------------
        - Handles user interactions for deposits, redemptions, and
          swaps across Birdieswap vaults.
        - All functions are externally callable and protected by
          reentrancy and pause modifiers.
        - Uses ERC4626 push model: assets are pulled from user,
          deposited into vaults, and returned post-operation.
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits a vanilla underlying token into its corresponding single vault, minting and transferring the bTokens to the caller.
     * @dev Caller must have approved the router to spend the underlying token. Reverts if deposits are globally paused or deposit-specific
     *      pause is active.
     * @param _underlyingTokenAddress The vanilla ERC20 token to deposit.
     * @param _underlyingTokenAmount  Amount of underlying tokens to deposit.
     * @return bTokenAmount           Amount of bTokens minted and transferred to the caller.
     */
    function singleDeposit(address _underlyingTokenAddress, uint256 _underlyingTokenAmount)
        external
        nonReentrant
        whenNotPaused
        whenDepositsActive
        returns (uint256)
    {
        // Deposit underlying token into its mapped single vault.
        (address bTokenAddress, uint256 bTokenAmount) =
            _depositUnderlyingToSingleVault(_underlyingTokenAddress, _underlyingTokenAmount, address(this));

        // Transfer the minted bTokens back to the user.
        _safePushToken(_msgSender(), bTokenAddress, bTokenAmount);

        return bTokenAmount;
    }

    /**
     * @notice Deposits two vanilla underlying tokens into their respective single vaults, converts them into bTokens, and supplies both
     *         into a dual vault (blpToken).
     * @dev    The `_accountForAccounting` parameter is used only for internal registry and analytics tracking within the dual vault; it
     *         does not affect custody.
     *
     *         After deposit:
     *          - The user receives minted blpTokens (dual vault LP shares).
     *          - Any unpaired residual underlying tokens are returned to the user.
     *
     * @param  _accountForAccounting    Address recorded in the dual vault for accounting only.
     * @param  _underlyingToken0Address Address of the first vanilla underlying token.
     * @param  _underlyingToken0Amount  Amount of the first underlying token to deposit.
     * @param  _underlyingToken1Address Address of the second vanilla underlying token.
     * @param  _underlyingToken1Amount  Amount of the second underlying token to deposit.
     * @return liquidityAmount          Amount of blpTokens minted to the user.
     * @return underlyingToken0Returned Amount of leftover token0 returned to the user (and reported).
     * @return underlyingToken1Returned Amount of leftover token1 returned to the user (and reported).
     */
    function dualDeposit(
        address _accountForAccounting,
        address _underlyingToken0Address,
        uint256 _underlyingToken0Amount,
        address _underlyingToken1Address,
        uint256 _underlyingToken1Amount
    ) external nonReentrant whenNotPaused whenDepositsActive returns (uint256, uint256, uint256) {
        // Deposit both underlying tokens into their corresponding single vaults.
        (address bToken0Address, uint256 bToken0Amount) =
            _depositUnderlyingToSingleVault(_underlyingToken0Address, _underlyingToken0Amount, address(this));
        (address bToken1Address, uint256 bToken1Amount) =
            _depositUnderlyingToSingleVault(_underlyingToken1Address, _underlyingToken1Amount, address(this));

        // Normalize token order (bToken0 < bToken1) to match canonical dual-vault ordering.
        (bToken0Address, bToken1Address, bToken0Amount, bToken1Amount) =
            _orderTokenPair(bToken0Address, bToken1Address, bToken0Amount, bToken1Amount);

        // Approve the dual vault to pull bTokens from the router.
        address blpTokenAddress = _getBLPTokenAddress(bToken0Address, bToken1Address);
        _safeApproveToken(bToken0Address, blpTokenAddress, bToken0Amount);
        _safeApproveToken(bToken1Address, blpTokenAddress, bToken1Amount);

        // Deposit both bTokens into the dual vault (minting blpTokens).
        address accountForAccounting = _accountForAccounting;
        (uint256 liquidityAmount, uint256 returnToken0Amount, uint256 returnToken1Amount) =
            IBirdieswapDualVaultV1(blpTokenAddress).deposit(accountForAccounting, bToken0Amount, bToken1Amount);
        _safeApproveToken(bToken0Address, blpTokenAddress, 0);
        _safeApproveToken(bToken1Address, blpTokenAddress, 0);

        // Redeem and return any unpaired residual bTokens to vanilla underlying.
        uint256 underlyingToken0ReturnedAmount = 0;
        uint256 underlyingToken1ReturnedAmount = 0;

        if (returnToken0Amount > 0) {
            (, underlyingToken0ReturnedAmount) = _redeemBTokenToUnderlying(bToken0Address, returnToken0Amount, false);
        }
        if (returnToken1Amount > 0) {
            (, underlyingToken1ReturnedAmount) = _redeemBTokenToUnderlying(bToken1Address, returnToken1Amount, false);
        }

        // Transfer minted blpTokens (dual vault LP shares) to the user.
        _safePushToken(_msgSender(), blpTokenAddress, liquidityAmount);

        return (liquidityAmount, underlyingToken0ReturnedAmount, underlyingToken1ReturnedAmount);
    }

    /**
     * @notice Redeems bTokens from a single vault back into vanilla underlying tokens.
     * @dev Caller must have approved the router to transfer their bTokens. Redeemed tokens are directly transferred to the caller.
     * @param _bTokenAddress The address of the single vault (bToken).
     * @param _bTokenAmount  The amount of bTokens to redeem.
     * @return underlyingTokenAmount Amount of vanilla underlying tokens returned to the caller.
     */
    function singleRedeem(address _bTokenAddress, uint256 _bTokenAmount) external nonReentrant whenNotPaused returns (uint256) {
        (, uint256 underlyingTokenAmount) = _redeemBTokenToUnderlying(_bTokenAddress, _bTokenAmount, true);
        return underlyingTokenAmount;
    }

    /**
     * @notice Redeems a blpToken into its two constituent bTokens, then converts each bToken back into vanilla underlying tokens.
     * @dev All resulting underlying tokens are sent to the caller, not to `_accountForAccounting`, which is used for internal vault
     *      bookkeeping only.
     * @param _accountForAccounting Accounting address used for registry and analytics (read-only context).
     * @param _blpTokenAddress      Dual vault (blpToken) address.
     * @param _blpTokenAmount       Amount of blpTokens to redeem.
     * @return underlyingToken0Amount Amount of underlying token0 returned to the caller.
     * @return underlyingToken1Amount Amount of underlying token1 returned to the caller.
     */
    function dualRedeem(address _accountForAccounting, address _blpTokenAddress, uint256 _blpTokenAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256, uint256)
    {
        // Pull blpTokens from the caller to this router.
        _blpTokenAmount = _resolveTokenAmount(_blpTokenAddress, _blpTokenAmount);
        _safePullToken(_msgSender(), _blpTokenAddress, _blpTokenAmount);

        // Redeem blpTokens into underlying bTokens (burning the shares).
        IBirdieswapDualVaultV1 blpToken = IBirdieswapDualVaultV1(_blpTokenAddress);
        (uint256 bToken0Amount, uint256 bToken1Amount) = blpToken.redeem(_accountForAccounting, address(this), _blpTokenAmount);

        // Redeem each bToken into vanilla underlying tokens.
        (address bToken0Address, address bToken1Address) = (blpToken.getToken0Address(), blpToken.getToken1Address());
        (, uint256 underlyingToken0Amount) = _redeemBTokenToUnderlying(bToken0Address, bToken0Amount, false);
        (, uint256 underlyingToken1Amount) = _redeemBTokenToUnderlying(bToken1Address, bToken1Amount, false);

        // Return both underlying tokens to the user.
        return (underlyingToken0Amount, underlyingToken1Amount);
    }

    /**
     * @notice Swaps one vanilla underlying token for another via an external DEX (Uniswap V3).
     * @dev The swap process involves:
     *        1. Depositing the input underlying token into its bToken vault.
     *        2. Swapping the bToken-in for bToken-out on the DEX.
     *        3. Redeeming bToken-out into vanilla underlying-out.
     *
     *      Includes `whenDepositsActive` because the swap internally performs deposits into the source single vault.
     *
     * @param _underlyingTokenInAddress  Input vanilla token address.
     * @param _feeTier                   Uniswap V3 pool fee tier used for the swap.
     * @param _underlyingTokenOutAddress Output vanilla token address.
     * @param _underlyingTokenInAmount   Amount of input underlying tokens to swap.
     * @param _underlyingTokenOutMinimumAmount Minimum acceptable amount of output underlying tokens.
     * @param _sqrtPriceLimitX96         Optional price limit parameter for Uniswap V3.
     * @param _referrerAddress           Optional address credited for the referral (for analytics only).
     * @return underlyingTokenOutAmount  Amount of output underlying tokens received.
     */
    function swap(
        address _underlyingTokenInAddress,
        uint24 _feeTier,
        address _underlyingTokenOutAddress,
        uint256 _underlyingTokenInAmount,
        uint256 _underlyingTokenOutMinimumAmount,
        uint160 _sqrtPriceLimitX96,
        address _referrerAddress
    ) external nonReentrant whenNotPaused whenSwapsActive whenDepositsActive returns (uint256) {
        // ─────────────────── Input Validation ────────────────────
        if (_underlyingTokenInAmount == 0) revert BirdieswapRouterV1__InvalidAmount();
        if (_feeTier == 0 || _underlyingTokenInAddress == _underlyingTokenOutAddress) revert BirdieswapRouterV1__InvalidSwapParameters();

        uint256 underlyingTokenOutAmount;
        address bTokenOutAddress = _getBTokenAddress(_underlyingTokenOutAddress);

        // ─────────────────── Execute Swap Flow ───────────────────
        {
            // Convert input underlying → bToken-in
            (address bTokenInAddress, uint256 bTokenInAmount) =
                _depositUnderlyingToSingleVault(_underlyingTokenInAddress, _underlyingTokenInAmount, address(this));

            // Approve Uniswap router to spend bToken-in
            address externalRouter = s_config.i_uniswapV3Router();
            _safeApproveToken(bTokenInAddress, externalRouter, bTokenInAmount);

            // Estimate minimum bToken-out based on expected underlying-out minimum
            uint256 bTokenOutMin = BirdieswapSingleVaultV1(bTokenOutAddress).previewFullWithdraw(_underlyingTokenOutMinimumAmount);

            // Perform swap via Uniswap V3
            uint256 bTokenOutAmount =
                _swapExactInputSingle(bTokenInAddress, _feeTier, bTokenOutAddress, bTokenInAmount, bTokenOutMin, _sqrtPriceLimitX96);

            // Reset approval (gas-efficient cleanup)
            _safeApproveToken(bTokenInAddress, externalRouter, 0);

            // Redeem bToken-out → underlying-out
            (, underlyingTokenOutAmount) = _redeemBTokenToUnderlying(bTokenOutAddress, bTokenOutAmount, false);
        }

        // ──────────────────── Post-Validation ────────────────────
        if (underlyingTokenOutAmount < _underlyingTokenOutMinimumAmount) revert BirdieswapRouterV1__MinimumAmountNetReceived();

        // Emit swap analytics event (uses tx.origin for reporting only, never for auth).
        try s_event.emitSwap(
            tx.origin,
            _msgSender(),
            _underlyingTokenInAddress,
            _feeTier,
            _underlyingTokenOutAddress,
            _underlyingTokenInAmount,
            underlyingTokenOutAmount,
            _referrerAddress
        ) { } catch { }

        return underlyingTokenOutAmount;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
        ------------------------------------------------------------
        - Core internal logic for ERC4626-based deposit/redeem flows.
        - Contains safe token transfer wrappers, Uniswap V3 integrations,
          and validation utilities.
        - Not directly accessible externally; used by router operations.
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Deposit Helpers ──────────────────────
    /**
     * @dev Internal helper that pulls a user's vanilla underlying token, approves
     *      the mapped single vault, and deposits it to mint bTokens.
     * @param _underlyingTokenAddress The vanilla ERC20 token address to deposit.
     * @param _underlyingTokenAmount  Amount of tokens to deposit. Supports `type(uint256).max` to deposit full balance.
     * @param _receiver               Recipient of the minted bTokens (often this router or the user).
     * @return bTokenAddress          Corresponding Birdieswap vault (bToken) address.
     * @return mintedAmount           Amount of bTokens minted by the deposit.
     */
    function _depositUnderlyingToSingleVault(address _underlyingTokenAddress, uint256 _underlyingTokenAmount, address _receiver)
        internal
        returns (address, uint256)
    {
        // ────────────────── Cache & Validation ───────────────────
        address bTokenAddress = _getBTokenAddress(_underlyingTokenAddress);
        IERC20 underlying = IERC20(_underlyingTokenAddress);
        BirdieswapSingleVaultV1 vault = BirdieswapSingleVaultV1(bTokenAddress);

        // ────────────── Resolve Amount & Pull Token ──────────────
        // Pull user's underlying tokens to this router.
        _underlyingTokenAmount = _resolveTokenAmount(_underlyingTokenAddress, _underlyingTokenAmount);
        _safePullToken(_msgSender(), _underlyingTokenAddress, _underlyingTokenAmount);

        // ─────────────────── Approve & Deposit ───────────────────
        // Approve the vault to spend underlying and trigger deposit.
        underlying.forceApprove(bTokenAddress, _underlyingTokenAmount);
        uint256 bTokenAmount = vault.deposit(_underlyingTokenAmount, _receiver);
        underlying.forceApprove(bTokenAddress, 0);

        return (bTokenAddress, bTokenAmount);
    }

    // ────────────────────── Redeem Helpers ───────────────────────
    /**
     * @dev Internal helper that redeems bTokens into vanilla underlying tokens
     *      and sends them to the caller. Pulls user’s bTokens if required.
     * @param _bTokenAddress          Address of the single vault (bToken).
     * @param _bTokenAmount           Amount of bTokens to redeem. Supports `type(uint256).max` for full balance.
     * @param _shouldPull             If true, pulls bTokens from the user before redeeming.
     * @return underlyingTokenAddress Vanilla underlying token address.
     * @return underlyingTokenAmount  Amount of vanilla underlying tokens redeemed and sent to user.
     */
    function _redeemBTokenToUnderlying(address _bTokenAddress, uint256 _bTokenAmount, bool _shouldPull)
        internal
        returns (address, uint256)
    {
        address msgSender = _msgSender();

        // ────────────────── Cache & Validation ───────────────────
        address underlyingTokenAddress = _getUnderlyingTokenAddress(_bTokenAddress);
        BirdieswapSingleVaultV1 vault = BirdieswapSingleVaultV1(_bTokenAddress);

        // ──────────── Optionally Pull User’s bTokens ─────────────
        if (_shouldPull) {
            _bTokenAmount = _resolveTokenAmount(_bTokenAddress, _bTokenAmount);
            _safePullToken(msgSender, _bTokenAddress, _bTokenAmount);
        }

        // ─────────────────── Redeem & Transfer ───────────────────
        // ERC4626 push model: shares are burned from this router.
        uint256 underlyingTokenAmount = vault.redeem(_bTokenAmount, address(this), address(this));

        // Push the redeemed underlying back to the user.
        _safePushToken(msgSender, underlyingTokenAddress, underlyingTokenAmount);

        return (underlyingTokenAddress, underlyingTokenAmount);
    }

    // ─────────────────────── Swap Helpers ────────────────────────
    /**
     * @dev Executes a Uniswap V3 exactInputSingle swap from one bToken to another.
     * @param _bTokenInAddress        Input bToken.
     * @param _feeTier                Uniswap V3 fee tier.
     * @param _bTokenOutAddress       Output bToken.
     * @param _bTokenInAmount         Amount of input bTokens to swap.
     * @param _bTokenOutMinimumAmount Minimum acceptable amount of output bTokens.
     * @param _sqrtPriceLimitX96      Optional Uniswap price limit.
     * @return bTokenOutAmount        Amount of output bTokens received.
     */
    function _swapExactInputSingle(
        address _bTokenInAddress,
        uint24 _feeTier,
        address _bTokenOutAddress,
        uint256 _bTokenInAmount,
        uint256 _bTokenOutMinimumAmount,
        uint160 _sqrtPriceLimitX96
    ) private returns (uint256) {
        address externalRouter = s_config.i_uniswapV3Router();
        uint256 bTokenOutAmount = ISwapRouter02(externalRouter).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: _bTokenInAddress,
                tokenOut: _bTokenOutAddress,
                fee: _feeTier,
                recipient: address(this),
                amountIn: _bTokenInAmount,
                amountOutMinimum: _bTokenOutMinimumAmount,
                sqrtPriceLimitX96: _sqrtPriceLimitX96
            })
        );

        return bTokenOutAmount;
    }

    // ──────────────── Internal Validation Helpers ────────────────
    /**
     * @dev Validates that a dual vault is structurally correct for the unordered
     *      pair (_bToken0, _bToken1). Ensures all addresses are nonzero, valid,
     *      and that the dual vault’s internal token pair matches the canonical order.
     * @param _bToken0   First single vault token.
     * @param _bToken1   Second single vault token.
     * @param _blpToken  Dual vault (blpToken) address to validate.
     */
    function _validateDualVaultMapping(address _bToken0, address _bToken1, address _blpToken) internal view {
        if (_blpToken == address(0) || _blpToken.code.length == 0) revert BirdieswapRouterV1__InvalidMapping();
        if (_bToken0 == _bToken1) revert BirdieswapRouterV1__InvalidMapping();
        if (_bToken0.code.length == 0 || _bToken1.code.length == 0) revert BirdieswapRouterV1__InvalidMapping();
        if (!(BirdieswapSingleVaultV1(_bToken0).previewFullDeposit(1) > 0)) revert BirdieswapRouterV1__InvalidMapping();
        if (!(BirdieswapSingleVaultV1(_bToken1).previewFullDeposit(1) > 0)) revert BirdieswapRouterV1__InvalidMapping();

        // Verify that the dual vault stores the correct ordered token pair.
        (address expected0, address expected1) = _orderAddresses(_bToken0, _bToken1);
        IBirdieswapDualVaultV1 dualVault = IBirdieswapDualVaultV1(_blpToken);
        (address token0, address token1) = (dualVault.getToken0Address(), dualVault.getToken1Address());
        if (token0 != expected0 || token1 != expected1) revert BirdieswapRouterV1__InvalidMapping();
    }

    /**
     * @dev Resolves a token amount for transfers, supporting `type(uint256).max`
     *      as a “use full balance” sentinel value. Verifies that allowance and
     *      balance are sufficient for transfer.
     * @param _tokenAddress Token to resolve.
     * @param _tokenAmount  Requested token amount.
     * @return resolvedAmount Effective amount validated for transfer.
     */
    function _resolveTokenAmount(address _tokenAddress, uint256 _tokenAmount) private view returns (uint256) {
        address msgSender = _msgSender();
        if (_tokenAmount == 0) revert BirdieswapRouterV1__InvalidAmount();

        IERC20 token = IERC20(_tokenAddress);
        uint256 actualBalance = token.balanceOf(msgSender);

        // Use full balance if sentinel value is provided.
        if (_tokenAmount == type(uint256).max) _tokenAmount = actualBalance;

        if (_tokenAmount > actualBalance) revert BirdieswapRouterV1__InsufficientBalance();
        if (_tokenAmount > token.allowance(msgSender, address(this))) revert BirdieswapRouterV1__ApprovalNeeded();

        uint256 resolvedAmount = _tokenAmount;

        return resolvedAmount;
    }

    // ────────────────── Token Transfer Helpers ───────────────────
    /**
     * @dev Safely pulls tokens from `_owner` into this contract.
     *      Wrapper for `safeTransferFrom`.
     */
    function _safePullToken(address _owner, address _tokenAddress, uint256 _tokenAmount) internal {
        IERC20(_tokenAddress).safeTransferFrom(_owner, address(this), _tokenAmount);
    }

    /**
     * @dev Safely pushes tokens from this contract to `_receiver`.
     *      Wrapper for `safeTransfer`.
     */
    function _safePushToken(address _receiver, address _tokenAddress, uint256 _tokenAmount) internal {
        IERC20(_tokenAddress).safeTransfer(_receiver, _tokenAmount);
    }

    /**
     * @dev Safely approves `_spenderAddress` to spend `_tokenAmount` of `_tokenAddress`.
     *      Uses `forceApprove` to overwrite existing allowance.
     */
    function _safeApproveToken(address _tokenAddress, address _spenderAddress, uint256 _tokenAmount) internal {
        IERC20(_tokenAddress).forceApprove(_spenderAddress, _tokenAmount);
    }

    // ────────────────────── Internal Views ───────────────────────
    /// @dev Resolves the single vault (bToken) mapped to a given underlying token.
    function _getBTokenAddress(address _underlyingTokenAddress) internal view returns (address) {
        address bTokenAddress = s_storage.underlyingToBToken(_underlyingTokenAddress);
        if (bTokenAddress == address(0)) revert BirdieswapRouterV1__SingleVaultNotFound();

        return bTokenAddress;
    }

    /// @dev Resolves the underlying token mapped to a given bToken.
    function _getUnderlyingTokenAddress(address _bTokenAddress) internal view returns (address) {
        address underlyingTokenAddress = s_storage.bTokenToUnderlying(_bTokenAddress);
        if (underlyingTokenAddress == address(0)) revert BirdieswapRouterV1__UnderlyingTokenNotFound();

        return underlyingTokenAddress;
    }

    /// @dev Resolves the dual vault (blpToken) mapped to an unordered pair of bTokens.
    function _getBLPTokenAddress(address _bToken0Address, address _bToken1Address) internal view returns (address) {
        address blpTokenAddress = s_storage.getBLPTokenAddress(_bToken0Address, _bToken1Address);
        if (blpTokenAddress == address(0)) revert BirdieswapRouterV1__DualVaultNotFound();

        return blpTokenAddress;
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Orders two addresses and returns (min, max).
    function _orderAddresses(address _a, address _b) private pure returns (address min, address max) {
        (min, max) = _a < _b ? (_a, _b) : (_b, _a);
    }

    /// @dev Orders a pair of token addresses and associated amounts.
    function _orderTokenPair(address _a, address _b, uint256 _aAmount, uint256 _bAmount)
        private
        pure
        returns (address minAddress, address maxAddress, uint256 minAmount, uint256 maxAmount)
    {
        return _a < _b ? (_a, _b, _aAmount, _bAmount) : (_b, _a, _bAmount, _aAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                ETC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Always reverts upon receiving an ERC721 token.
     * @dev Prevents NFTs from being accidentally transferred into the router.
     */
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data) external pure returns (bytes4) {
        revert BirdieswapRouterV1__NotAllowedNFT(_operator, _from, _tokenId, _data);
    }
}
/*//////////////////////////////////////////////////////////////
                          END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant The Router never performs callbacks or external calls into user contracts.
/// @custom:invariant Single vault mappings are bijective:
///                  `underlyingToBToken[x] == y` ⇔ `bTokenToUnderlying[y] == x`.
/// @custom:invariant Dual vault mappings are bijective:
///                  `bTokenPairToBLPToken[x,y] == z` ⇔ `blpTokenToBTokenPair[z] == (x,y)`.
/// @custom:invariant Dual vault (blpToken) mappings are ordered and one-to-one with valid bToken pairs.
/// @custom:invariant Global pause halts all state-changing functions; deposit pause halts deposits and swaps only.
/// @custom:invariant Upgradeability preserves storage layout and UUPS authorization is restricted to UPGRADER_ROLE().
/// @custom:invariant Router holds no permanent user funds beyond transient transfer scopes during operations.
