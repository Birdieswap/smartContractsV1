// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { Pausable } from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "./BirdieswapConfigV1.sol";
import { BirdieswapRoleSignaturesV1 } from "../src/BirdieswapRoleSignaturesV1.sol";
import { BirdieswapStorageV1 } from "./BirdieswapStorageV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapRoleRouterV1 } from "./interfaces/IBirdieswapRoleRouterV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapStakingV1
 * @author Birdieswap
 * @notice Stake BLP tokens to earn multiple ERC20 reward tokens simultaneously.
 *
 * @dev Overview
 * - Supports up to `i_maxRewardTokens` concurrent reward tokens per pool.
 * - Implements deterministic reward emission via fixed‐rate schedules.
 * - Uses `Math.mulDiv` and `i_precision` scaling for overflow‐safe fixed-point arithmetic.
 * - Preserves small rounding dust (≤ i_precision-1 per user/reward) for consistency.
 * - Compatible only with standard, non-rebasing ERC20 staking tokens.
 *
 * @dev Design Principles
 * - Fully non-upgradeable; to modify logic, deploy a new version (V2, V3, …).
 * - Strict CEI (Checks–Effects–Interactions) ordering and isolated reentrancy domains.
 * - Role-based access control enforced through the global RoleRouter.
 * - All protocol events emitted via the centralized EventRelayer for analytics consistency.
 *
 * @dev Security Considerations
 * - Global and local pause controls allow emergency response without seizing funds.
 * - Reward accounting is monotonic and precision-bounded.
 * - Internal reentrancy guard prevents nested internal calls.
 */
contract BirdieswapStakingV1 is ReentrancyGuard, Pausable, BirdieswapRoleSignaturesV1 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    // ──────────────────── Generic / Validation ────────────────────
    error BirdieswapStakingV1__ZeroAddressNotAllowed(); // Zero address not allowed.
    error BirdieswapStakingV1__InvalidAmount(); // Amount is zero or exceeds limits.
    error BirdieswapStakingV1__UnauthorizedAccess(); // Caller lacks required role.
    error BirdieswapStakingV1__ReentrantCall(); // Internal reentrancy guard triggered.

    // ─────────────────────── Staking Logic ───────────────────────
    error BirdieswapStakingV1__ExceededMaxCap(); // New total supply exceeds i_maxTotalSupply.
    error BirdieswapStakingV1__InsufficientBalance(); // Withdraw amount exceeds user balance.

    // ───────────────────── Reward Management ─────────────────────
    error BirdieswapStakingV1__PrcisionZero(); // Precision cannot be zero.
    error BirdieswapStakingV1__InvalidRewardIndex(); // Reward index out of bounds.
    error BirdieswapStakingV1__DuplicatedClaimIndex(); // Duplicate reward index in claimMany.
    error BirdieswapStakingV1__DuplicatedRewardToken(); // Reward token already added.
    error BirdieswapStakingV1__ExceededMaxRewardTokens(); // Reward token count exceeds i_maxRewardTokens.
    error BirdieswapStakingV1__RewardTokenNotWhitelisted(); // Reward token not whitelisted.
    error BirdieswapStakingV1__StakingTokenCannotBeRewardToken(); // Staking token cannot be a reward token.
    error BirdieswapStakingV1__InvalidDuration(); // Emission duration outside [i_minDuration, i_maxDuration].
    error BirdieswapStakingV1__RewardSpeedTooHigh(); // Computed emission speed exceeds i_maxRewardSpeed.
    error BirdieswapStakingV1__InsufficientContractBalance(); // Contract lacks enough rewards to honor schedule.

    // ──────────────────── Governance / Rescue ────────────────────
    error BirdieswapStakingV1__CannotRescueRewardToken(); // Attempt to rescue an active reward token.
    error BirdieswapStakingV1__CannotRescueStakingToken(); // Attempt to rescue the staking token.

    // ─────────────────────── Pause Control ───────────────────────
    error BirdieswapStakingV1__GlobalPauseActive(); // Function blocked while global pause is active.

    error BirdieswapStakingV1__DepositsAlreadyPaused(); // Deposits already paused.
    error BirdieswapStakingV1__DepositsNotPaused(); // Deposits not currently paused.
    error BirdieswapStakingV1__DepositsPaused(); // Deposit attempt while deposits paused.

    error BirdieswapStakingV1__WithdrawalsAlreadyPaused(); // Withdrawals already paused.
    error BirdieswapStakingV1__WithdrawalsNotPaused(); // Withdrawals not currently paused.
    error BirdieswapStakingV1__WithdrawalsPaused(); // Withdraw attempt while withdrawals paused.

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Version Info ────────────────────────
    /// @notice Contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapStakingV1";

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // ───────────────────────── Core Modules ──────────────────────
    BirdieswapStorageV1 private immutable i_storage; // Global storage module.
    IBirdieswapRoleRouterV1 private immutable i_role; // Global role router.
    IBirdieswapEventRelayerV1 private immutable i_event; // Event relayer contract.

    // ───────────────────────── Pool Assets ───────────────────────
    IERC20 private immutable i_stakingToken; // Immutable staking token accepted by the pool.

    // ───────────────────────── Precision Base ────────────────────
    /// @notice Fixed-point precision scalar used in reward accounting (e.g., 1e18).
    uint256 private immutable i_precision;

    // ───────────────────────── Config Caps ───────────────────────
    /// @notice Maximum emission speed (tokens/sec assuming 18 decimals).
    uint256 private immutable i_maxRewardSpeed;
    /// @notice Maximum reward funding amount per schedule.
    uint256 private immutable i_maxRewardPerFunding;
    /// @notice Maximum number of concurrent reward tokens.
    uint256 private immutable i_maxRewardTokens;
    /// @notice Emission duration bounds (in seconds).
    uint256 private immutable i_maxDuration;
    uint256 private immutable i_minDuration;
    /// @notice Hard cap on total staking supply.
    uint256 private immutable i_maxTotalSupply;

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Pool Accounting ─────────────────────
    uint256 private s_totalSupply; // Current total amount of staked tokens.

    mapping(address => uint256) public balanceOf; // User -> staked balance.
    mapping(address => mapping(uint256 => uint256)) public userRewardAccrued; // User -> reward index -> accrued rewards.
    mapping(address => mapping(uint256 => uint256)) public userRewardPerTokenPaid; // User -> reward index -> checkpointed per-token rate.

    // ───────────────────── Reward Configuration ──────────────────
    RewardInfo[] private rewards; // Active reward token schedules.

    // ─────────────────────── Control Flags ───────────────────────
    bool internal _depositsPaused; // Deposit pause flag (GUARDIAN_ROLE).
    bool internal _withdrawalsPaused; // Withdrawal pause flag (MANAGER_ROLE).
    bool internal _internalEntered; // Internal reentrancy guard flag.

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reward token configuration.
     * @param rewardToken           ERC20 token used for rewards.
     * @param rewardPerTokenStored  Cumulative rewards per staked token (scaled by i_precision).
     * @param lastUpdate            Last timestamp rewards were updated (capped by periodFinish).
     * @param rewardSpeed           Emission speed in tokens per second.
     * @param periodFinish          Timestamp (inclusive cap) when the current schedule ends.
     */
    struct RewardInfo {
        IERC20 rewardToken;
        uint256 rewardPerTokenStored;
        uint256 lastUpdate;
        uint256 rewardSpeed;
        uint256 periodFinish;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the staking pool and binds immutable protocol modules.
     *
     * @param configAddress_        Address of the Birdieswap Config contract.
     * @param storageAddress_       Address of the Birdieswap Storage contract.
     * @param stakingTokenAddress_  ERC20 token address accepted for staking (blpToken).
     * @param roleRouterAddress_    Address of the global RoleRouter.
     * @param eventRelayerAddress_  Address of the global EventRelayer.
     *
     * @dev Initialization flow:
     *  1. Validates all input addresses.
     *  2. Caches immutable references to global modules (Config, Storage, Roles, Events).
     *  3. Reads emission parameters and caps from the Config contract.
     *  4. Checks reward-speed safety bounds against precision scaling.
     *
     * @dev Governance role overview:
     *  - DEFAULT_ADMIN_ROLE (timelocked multisig): manages whitelisting and role delegation.
     *  - MANAGER_ROLE (secure multisig): handles reward additions, pauses, and token rescues.
     *  - DISTRIBUTOR_ROLE (operational wallet): funds reward schedules under caps.
     */
    constructor(
        address configAddress_,
        address storageAddress_,
        address stakingTokenAddress_,
        address roleRouterAddress_,
        address eventRelayerAddress_
    ) {
        //──────────────────── Input Validation ────────────────────
        if (configAddress_ == address(0)) revert BirdieswapStakingV1__ZeroAddressNotAllowed();
        if (storageAddress_ == address(0)) revert BirdieswapStakingV1__ZeroAddressNotAllowed();
        if (stakingTokenAddress_ == address(0)) revert BirdieswapStakingV1__ZeroAddressNotAllowed();
        if (roleRouterAddress_ == address(0)) revert BirdieswapStakingV1__ZeroAddressNotAllowed();
        if (eventRelayerAddress_ == address(0)) revert BirdieswapStakingV1__ZeroAddressNotAllowed();

        //──────────────────── Module Bindings ─────────────────────
        BirdieswapConfigV1 config = BirdieswapConfigV1(configAddress_);
        i_storage = BirdieswapStorageV1(storageAddress_);
        i_role = IBirdieswapRoleRouterV1(roleRouterAddress_);
        i_event = IBirdieswapEventRelayerV1(eventRelayerAddress_);
        i_stakingToken = IERC20(stakingTokenAddress_);

        //─────────────────── Precision & Safety ───────────────────
        i_precision = config.PRECISION_18();
        if (i_precision == 0) revert BirdieswapStakingV1__PrcisionZero();
        if (config.i_maxRewardSpeed() > type(uint256).max / i_precision) revert BirdieswapStakingV1__RewardSpeedTooHigh();

        //─────────────────── Config Parameters ────────────────────
        i_maxRewardSpeed = config.i_maxRewardSpeed();
        i_maxRewardPerFunding = config.i_maxRewardPerFunding();
        i_maxRewardTokens = config.i_maxRewardTokens();
        i_maxDuration = config.i_maxDuration();
        i_minDuration = config.i_minDuration();
        i_maxTotalSupply = config.i_maxTotalSupply();

        if (i_maxDuration != 0 && i_maxRewardSpeed > type(uint256).max / i_maxDuration) revert BirdieswapStakingV1__RewardSpeedTooHigh();
        if (i_maxRewardTokens > 256) revert BirdieswapStakingV1__ExceededMaxRewardTokens();
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── Reentrancy Guard ──────────────────────
    /**
     * @notice Internal-only reentrancy guard (lightweight complement to {nonReentrant}).
     * @dev
     * - Prevents reentrant calls to internal or private functions that are *not*
     *   externally visible (and thus not protected by {nonReentrant}).
     * - Useful when a `nonReentrant` external function calls another internal routine
     *   that could be reentered indirectly (e.g., via token callbacks).
     * - Reverts with {BirdieswapStakingV1__ReentrantCall} if a reentrant call is detected.
     *
     * Implementation details:
     * - May be safely used alongside the external `nonReentrant` modifier,
     *   since it uses an independent `_internalEntered` flag.
     * - Must not be nested within itself in the same call frame.
     *
     * @custom:security Uses a local storage flag identical in behavior to OpenZeppelin’s pattern.
     */
    modifier nonReentrantInternal() {
        if (_internalEntered) revert BirdieswapStakingV1__ReentrantCall();
        _internalEntered = true;
        _;
        _internalEntered = false;
    }

    // ───────────────────── Role-Based Access ─────────────────────
    /**
     * @notice Restricts function access to global UNPAUSER_ROLE.
     * @dev Used for unpausing global/deposit/withdraw flags.
     */
    modifier onlyUnpauserRole() {
        if (!i_role.hasRoleGlobal(UNPAUSER_ROLE, msg.sender)) {
            revert BirdieswapStakingV1__UnauthorizedAccess();
        }
        _;
    }

    /**
     * @notice Restricts function access to global MANAGER_ROLE.
     * @dev Used for pool management, reward token addition, and rescue operations.
     */
    modifier onlyManagerRole() {
        if (!i_role.hasRoleGlobal(MANAGER_ROLE, msg.sender)) {
            revert BirdieswapStakingV1__UnauthorizedAccess();
        }
        _;
    }

    /**
     * @notice Restricts function access to GUARDIAN_ROLE or GUARDIAN_FULL_ROLE.
     * @dev Used primarily for activating emergency or temporary pauses.
     */
    modifier onlyGuardianRole() {
        if (!(i_role.hasRoleGlobal(GUARDIAN_ROLE, msg.sender) || i_role.hasRoleGlobal(GUARDIAN_FULL_ROLE, msg.sender))) {
            revert BirdieswapStakingV1__UnauthorizedAccess();
        }
        _;
    }

    /**
     * @notice Restricts function access to global DISTRIBUTOR_ROLE.
     * @dev Used for funding reward schedules.
     */
    modifier onlyDistributorRole() {
        if (!i_role.hasRoleGlobal(DISTRIBUTOR_ROLE, msg.sender)) {
            revert BirdieswapStakingV1__UnauthorizedAccess();
        }
        _;
    }

    // ───────────────────── Pause Conditions ──────────────────────
    /**
     * @notice Ensures deposits are not paused and no global pause is active.
     * @dev Used in deposit flows to block actions during global or deposit-specific pauses.
     */
    modifier whenDepositsNotPaused() {
        if (paused()) revert BirdieswapStakingV1__GlobalPauseActive();
        if (_depositsPaused) revert BirdieswapStakingV1__DepositsPaused();
        _;
    }

    /**
     * @notice Ensures withdrawals are not paused and no global pause is active.
     * @dev Used in withdraw flows to block actions during global or withdrawal-specific pauses.
     */
    modifier whenWithdrawalsNotPaused() {
        if (paused()) revert BirdieswapStakingV1__GlobalPauseActive();
        if (_withdrawalsPaused) revert BirdieswapStakingV1__WithdrawalsPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── Staking ──────────────────────────
    /**
     * @notice Deposit staking tokens without claiming rewards.
     * @param _stakeAmount The amount of staking tokens to deposit.
     * @custom:interaction NonReentrant, CEI-compliant.
     * @custom:security Reverts if deposits are paused or global pause is active.
     */
    function deposit(uint256 _stakeAmount) external nonReentrant whenDepositsNotPaused {
        _deposit(_stakeAmount);
    }

    /**
     * @notice Deposit staking tokens and claim all available rewards in a single call.
     * @param _stakeAmount The amount of staking tokens to deposit.
     * @dev Performs identical accounting to {deposit}, followed by `_claimAllTo(msg.sender)`.
     */
    function depositAndClaimAll(uint256 _stakeAmount) external nonReentrant whenDepositsNotPaused {
        _deposit(_stakeAmount);
        _claimAllTo(msg.sender);
    }

    /**
     * @notice Withdraw staked tokens without claiming rewards.
     * @param _withdrawAmount The amount of staking tokens to withdraw.
     * @dev Rewards are snapshotted before balance reduction to preserve accrual integrity.
     */
    function withdraw(uint256 _withdrawAmount) external nonReentrant whenWithdrawalsNotPaused {
        _withdraw(_withdrawAmount);
    }

    /**
     * @notice Withdraw staked tokens and claim all rewards in a single call.
     * @param _withdrawAmount The amount of staking tokens to withdraw.
     * @dev Equivalent to {withdraw} followed by `_claimAllTo(msg.sender)`.
     */
    function withdrawAndClaimAll(uint256 _withdrawAmount) external nonReentrant whenWithdrawalsNotPaused {
        _withdraw(_withdrawAmount);
        _claimAllTo(msg.sender);
    }

    // ───────────────────────── Claiming ──────────────────────────
    /**
     * @notice Claim rewards for a single reward token index.
     * @param _rewardIndex The index of the reward token to claim.
     * @custom:interaction NonReentrant; updates and pays reward atomically.
     * @custom:security If the contract’s reward balance is insufficient, a partial payment occurs
     * (see {RewardPartiallyPaid} event).
     */
    function claim(uint256 _rewardIndex) external nonReentrant whenNotPaused {
        _assertValidIndex(_rewardIndex);

        // Update accounting
        _updateRewards(msg.sender, _singleIndex(_rewardIndex));

        uint256 accrued = userRewardAccrued[msg.sender][_rewardIndex];
        if (accrued != 0) _payoutReward(msg.sender, _rewardIndex, accrued);
    }

    /**
     * @notice Claim multiple reward tokens in a single transaction.
     * @param _rewardIndices Array of reward token indices to claim.
     * @dev
     * - Gas-optimized compared to multiple `claim()` calls.
     * - Guards against:
     *   1. Excessive length (> i_maxRewardTokens).
     *   2. Out-of-bounds indices.
     *   3. Duplicate indices (via boolean deduplication array).
     * - Fully safe even if `rewards.length > 256`.
     */
    function claimMany(uint256[] calldata _rewardIndices) external nonReentrant whenNotPaused {
        uint256 length = _rewardIndices.length;
        if (length == 0) return; // No-op for empty input
        if (length > i_maxRewardTokens) revert BirdieswapStakingV1__ExceededMaxRewardTokens();

        uint256 totalRewards = rewards.length;

        // ──────────────── Single-Index Fast Path ─────────────────
        // If only one index is given, skip the allocation of a boolean array.
        if (length == 1) {
            uint256 rewardIndex = _rewardIndices[0];
            if (rewardIndex >= totalRewards) revert BirdieswapStakingV1__InvalidRewardIndex();

            _updateRewards(msg.sender, _rewardIndices);

            uint256 accrued = userRewardAccrued[msg.sender][rewardIndex];
            if (accrued != 0) _payoutReward(msg.sender, rewardIndex, accrued);
            return;
        }

        // ────────────────── Deduplication Path ───────────────────
        bool[] memory seen = new bool[](totalRewards);

        // Validate and deduplicate indices
        for (uint256 i = 0; i < length;) {
            uint256 rewardIndex = _rewardIndices[i];
            if (rewardIndex >= totalRewards) revert BirdieswapStakingV1__InvalidRewardIndex();
            if (seen[rewardIndex]) revert BirdieswapStakingV1__DuplicatedClaimIndex();

            seen[rewardIndex] = true;
            unchecked {
                ++i;
            }
        }

        // ─────────────────── Accounting Update ───────────────────
        _updateRewards(msg.sender, _rewardIndices);

        // ──────────────────── Payout Rewards ─────────────────────
        for (uint256 i = 0; i < length;) {
            uint256 rewardIndex = _rewardIndices[i];
            uint256 accrued = userRewardAccrued[msg.sender][rewardIndex];
            if (accrued != 0) _payoutReward(msg.sender, rewardIndex, accrued);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Claim all available rewards across all reward tokens.
     * @dev Emits multiple {RewardPaid} events and one aggregate {ClaimAll} event.
     * @custom:interaction NonReentrant, CEI-compliant.
     */
    function claimAll() external nonReentrant whenNotPaused {
        uint256[] memory empty;
        _updateRewards(msg.sender, empty);
        _claimAllTo(msg.sender);
    }

    // ───────────────────────── Emergency ─────────────────────────
    /**
     * @notice Withdraw all staked tokens immediately, forfeiting all unclaimed rewards.
     * @dev
     * - Resets user’s staked balance and reward accruals.
     * - Emits both {EmergencyWithdraw} and {RewardsForfeited}.
     * @custom:interaction NonReentrant, CEI-compliant.
     * @custom:security Designed strictly for user self-rescue during failures;
     * cannot be abused for reentrancy or reward manipulation.
     */
    function emergencyWithdraw() external nonReentrant whenWithdrawalsNotPaused {
        uint256 userBalance = balanceOf[msg.sender];
        if (userBalance == 0) revert BirdieswapStakingV1__InsufficientBalance();

        // Reset staked balance and total supply
        balanceOf[msg.sender] = 0;
        s_totalSupply -= userBalance;

        // Forfeit all accrued rewards
        uint256 length = rewards.length;
        uint256[] memory forfeited = new uint256[](length);
        uint256[] memory indices = new uint256[](length);

        for (uint256 i = 0; i < length;) {
            uint256 rpt = _getRewardPerToken(i);
            uint256 rewardAmount = userRewardAccrued[msg.sender][i];

            // Clear state
            delete userRewardAccrued[msg.sender][i];
            userRewardPerTokenPaid[msg.sender][i] = rpt;

            forfeited[i] = rewardAmount;
            indices[i] = i;

            unchecked {
                ++i;
            }
        }

        // Return staked tokens only
        SafeERC20.safeTransfer(i_stakingToken, msg.sender, userBalance);

        // Emit global recovery events
        try i_event.emitEmergencyWithdraw(msg.sender, userBalance, address(i_stakingToken)) { } catch { }
        try i_event.emitRewardsForfeited(msg.sender, indices, forfeited) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Contract Info ───────────────────────
    /// @notice Returns the contract version identifier.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /// @notice Returns the staking token address accepted by this pool.
    function getStakingToken() external view returns (address) {
        return address(i_stakingToken);
    }

    /// @notice Returns the current total amount of staked tokens.
    function getTotalSupply() external view returns (uint256) {
        return s_totalSupply;
    }

    // ────────────────────── Reward Metadata ──────────────────────
    /// @notice Returns the total number of active reward tokens.
    function getRewardCount() external view returns (uint256) {
        return rewards.length;
    }

    /**
     * @notice Returns all active reward token addresses.
     * @return tokens Array of ERC20 reward token addresses.
     */
    function getAllRewardTokens() external view returns (address[] memory tokens) {
        uint256 length = rewards.length;
        tokens = new address[](length);
        for (uint256 i = 0; i < length;) {
            tokens[i] = address(rewards[i].rewardToken);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Reads reward schedule metadata for a given reward index.
     * @param _rewardIndex Index of the reward token.
     * @return token                ERC20 reward token address.
     * @return rewardPerTokenStored Cumulative reward per token (scaled by i_precision).
     * @return lastUpdate           Timestamp of last reward update.
     * @return rewardSpeed          Emission rate (tokens per second).
     * @return periodFinish         End timestamp of the current emission schedule.
     */
    function getRewardInfo(uint256 _rewardIndex)
        external
        view
        returns (address token, uint256 rewardPerTokenStored, uint256 lastUpdate, uint256 rewardSpeed, uint256 periodFinish)
    {
        _assertValidIndex(_rewardIndex);
        RewardInfo storage rewardInfo = rewards[_rewardIndex];

        return (
            address(rewardInfo.rewardToken),
            rewardInfo.rewardPerTokenStored,
            rewardInfo.lastUpdate,
            rewardInfo.rewardSpeed,
            rewardInfo.periodFinish
        );
    }

    /**
     * @notice Returns the remaining undistributed tokens for an ongoing reward schedule.
     * @param _rewardIndex Index of the reward token.
     * @return remaining Remaining tokens yet to be emitted.
     */
    function getTotalOutstanding(uint256 _rewardIndex) external view returns (uint256 remaining) {
        _assertValidIndex(_rewardIndex);
        RewardInfo storage rewardInfo = rewards[_rewardIndex];

        if (block.timestamp >= rewardInfo.periodFinish) return 0;
        return rewardInfo.rewardSpeed * (rewardInfo.periodFinish - block.timestamp);
    }

    /**
     * @notice Returns the current cumulative reward-per-token value for a given index.
     * @param _rewardIndex Index of the reward token in `rewards`.
     * @return rewardPerToken Current reward per staked token (scaled by i_precision).
     */
    function getRewardPerToken(uint256 _rewardIndex) public view returns (uint256 rewardPerToken) {
        return _getRewardPerToken(_rewardIndex);
    }

    // ────────────────────── User Accounting ──────────────────────
    /**
     * @notice Computes total earned but unclaimed rewards for a user and a given reward token.
     * @param _userAddress The user address to query.
     * @param _rewardIndex The reward token index.
     * @return total The user’s total earned rewards (claimed + unclaimed).
     */
    function earned(address _userAddress, uint256 _rewardIndex) public view returns (uint256 total) {
        _assertValidIndex(_rewardIndex);

        uint256 pending = Math.mulDiv(
            balanceOf[_userAddress], _getRewardPerToken(_rewardIndex) - userRewardPerTokenPaid[_userAddress][_rewardIndex], i_precision
        );

        total = pending + userRewardAccrued[_userAddress][_rewardIndex];
    }

    /**
     * @notice View helper to read all pending rewards for a set of indices.
     * @param _account User address to query.
     * @param _rewardIndices List of reward indices to check.
     * @return pendingRewards Array of unclaimed reward amounts (1:1 with `_rewardIndices`).
     */
    function getPendingRewards(address _account, uint256[] calldata _rewardIndices)
        external
        view
        returns (uint256[] memory pendingRewards)
    {
        uint256 length = _rewardIndices.length;
        pendingRewards = new uint256[](length);

        for (uint256 i = 0; i < length;) {
            pendingRewards[i] = earned(_account, _rewardIndices[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ──────────────────────── Pause State ────────────────────────
    /// @notice Returns true if deposits are paused.
    function depositsPaused() public view returns (bool) {
        return _depositsPaused;
    }

    /// @notice Returns true if withdrawals are paused.
    function withdrawalsPaused() public view returns (bool) {
        return _withdrawalsPaused;
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE / MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Governance and access control overview.
     *
     * Roles:
     * - DEFAULT_ADMIN_ROLE (timelocked multisig): manages whitelisting and global role assignments.
     * - MANAGER_ROLE (secure multisig): adds reward tokens, manages pauses, rescues stray ERC20s.
     * - DISTRIBUTOR_ROLE (operational wallet): funds reward schedules within configured caps.
     *
     * Security notes:
     * - Governance may freeze deposits or withdrawals but cannot seize staked assets.
     * - Only canonical ERC20s should be whitelisted; non-standard tokens (rebasing or fee-on-transfer)
     *   may corrupt reward accounting.
     */

    // ───────────────────── Reward Management ─────────────────────
    /**
     * @notice Adds a new reward token to the staking pool (cannot be removed once added).
     * @custom:governance Only callable by accounts with MANAGER_ROLE.
     * @param _rewardToken The ERC20 reward token address to register.
     *
     * @dev Enforces:
     * - Non-zero address.
     * - Token whitelisted in global storage.
     * - Token is not identical to the staking token.
     * - Token not already added.
     * - Total reward token count below `i_maxRewardTokens`.
     *
     * Emits:
     * - {RewardTokenAdded} via EventRelayer.
     */
    function addRewardToken(address _rewardToken) external onlyManagerRole {
        if (_rewardToken == address(0)) revert BirdieswapStakingV1__ZeroAddressNotAllowed();
        if (!i_storage.rewardTokenWhitelist(_rewardToken)) revert BirdieswapStakingV1__RewardTokenNotWhitelisted();
        if (_rewardToken == address(i_stakingToken)) revert BirdieswapStakingV1__StakingTokenCannotBeRewardToken();

        uint256 length = rewards.length;
        for (uint256 i = 0; i < length;) {
            if (address(rewards[i].rewardToken) == _rewardToken) revert BirdieswapStakingV1__DuplicatedRewardToken();
            unchecked {
                ++i;
            }
        }

        if (length >= i_maxRewardTokens) revert BirdieswapStakingV1__ExceededMaxRewardTokens();

        rewards.push(
            RewardInfo({
                rewardToken: IERC20(_rewardToken),
                rewardPerTokenStored: 0,
                lastUpdate: block.timestamp,
                rewardSpeed: 0,
                periodFinish: block.timestamp
            })
        );

        try i_event.emitRewardTokenAdded(length, _rewardToken) { } catch { }
    }

    /**
     * @notice Funds or extends a reward schedule for a given reward token.
     * @custom:governance Only callable by accounts with DISTRIBUTOR_ROLE.
     * @param _rewardIndex  The reward token index to fund.
     * @param _rewardAmount The number of tokens to fund (≤ i_maxRewardPerFunding).
     * @param _duration     Duration of the emission period, in seconds.
     *
     * @dev Operational flow:
     *  1. Pulls tokens from the distributor wallet.
     *  2. Snapshots `rewardPerTokenStored` and `lastUpdate`.
     *  3. If an active schedule exists, rolls leftover emissions into the new round.
     *  4. Calculates a new emission rate and validates safety caps.
     *  5. Ensures contract balance covers full new schedule before committing.
     *
     * Security:
     * - Enforces funding caps per transaction.
     * - Caps emission speed to prevent overflow or token drain.
     * - Prevents underfunded schedules.
     *
     * Emits:
     * - {RewardFunded} via EventRelayer.
     */
    function fundReward(uint256 _rewardIndex, uint256 _rewardAmount, uint256 _duration) external nonReentrant onlyDistributorRole {
        _assertValidIndex(_rewardIndex);

        // Validate funding parameters
        if (_rewardAmount == 0 || _rewardAmount > i_maxRewardPerFunding) revert BirdieswapStakingV1__InvalidAmount();
        if (_duration > i_maxDuration || _duration < i_minDuration) revert BirdieswapStakingV1__InvalidDuration();

        RewardInfo storage rewardInfo = rewards[_rewardIndex];
        IERC20 token = rewardInfo.rewardToken;

        // Pull tokens from distributor wallet
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), _rewardAmount);

        // Snapshot current state before recomputing schedule
        rewardInfo.rewardPerTokenStored = _getRewardPerToken(_rewardIndex);
        rewardInfo.lastUpdate = _lastTimeRewardApplicable(_rewardIndex);

        uint256 totalFunding = _rewardAmount;
        uint256 leftover;

        // Roll over unspent rewards if schedule still active
        if (block.timestamp < rewardInfo.periodFinish) {
            uint256 remaining = rewardInfo.periodFinish - block.timestamp;
            leftover = rewardInfo.rewardSpeed * remaining;
            totalFunding += leftover;
        }

        // Add any residual dust from prior funding rounds
        uint256 currentBalance = token.balanceOf(address(this));
        uint256 alreadyCommitted =
            rewardInfo.rewardSpeed * (rewardInfo.periodFinish > block.timestamp ? (rewardInfo.periodFinish - block.timestamp) : 0);

        if (currentBalance > alreadyCommitted + _rewardAmount) {
            uint256 dust = currentBalance - (alreadyCommitted + _rewardAmount);
            totalFunding += dust;
        }

        // Compute new emission rate (floor division; leftover dust retained for next funding)
        uint256 newRate = totalFunding / _duration;
        if (newRate > i_maxRewardSpeed) revert BirdieswapStakingV1__RewardSpeedTooHigh();

        uint256 newPeriodFinish = block.timestamp + _duration;
        uint256 outstanding = newRate * _duration;

        // Verify sufficient balance to cover full emission
        if (currentBalance < outstanding) revert BirdieswapStakingV1__InsufficientContractBalance();

        // Commit new schedule
        rewardInfo.rewardSpeed = newRate;
        rewardInfo.periodFinish = newPeriodFinish;

        try i_event.emitRewardFunded(_rewardIndex, _rewardAmount, _duration, msg.sender, leftover, totalFunding, newRate) { } catch { }
    }

    // ────────────────────── Asset Recovery ───────────────────────
    /**
     * @notice Recovers an ERC20 token accidentally sent to the staking contract.
     * @custom:governance Only callable by accounts with MANAGER_ROLE.
     * @param _tokenAddress    Token to rescue (cannot be staking or active reward token).
     * @param _receiverAddress Address to receive rescued tokens.
     * @param _amount          Amount of tokens to transfer.
     *
     * @dev
     * - Skips active reward tokens and the staking token.
     * - Intended for external tokens mistakenly sent to the contract.
     * - Emits {ERC20RescuedFromStaking}.
     */
    function rescueERC20(address _tokenAddress, address _receiverAddress, uint256 _amount) external onlyManagerRole nonReentrant {
        uint256 length = rewards.length;

        // Ensure token is not an active reward
        for (uint256 i = 0; i < length;) {
            if (address(rewards[i].rewardToken) == _tokenAddress) revert BirdieswapStakingV1__CannotRescueRewardToken();
            unchecked {
                ++i;
            }
        }

        // Ensure token is not the staking token
        if (_tokenAddress == address(i_stakingToken)) revert BirdieswapStakingV1__CannotRescueStakingToken();
        SafeERC20.safeTransfer(IERC20(_tokenAddress), _receiverAddress, _amount);
        try i_event.emitERC20RescuedFromStaking(_tokenAddress, _amount, _receiverAddress, msg.sender) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSING LOGIC
                  (global pause supersedes local flags)                           
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause all contract functions (global pause).
     * @custom:governance Only GUARDIAN_ROLE / GUARDIAN_FULL_ROLE.
     */
    function pause() external onlyGuardianRole {
        _pause();
        try i_event.emitStakingGlobalPaused(msg.sender) { } catch { }
    }

    /**
     * @notice Unpause all contract functions (global).
     * @custom:governance Only UNPAUSER_ROLE.
     */
    function unpause() external onlyUnpauserRole {
        _unpause();
        try i_event.emitStakingGlobalUnpaused(msg.sender) { } catch { }
    }

    /**
     * @notice Pause only deposits.
     * @custom:governance Only GUARDIAN_ROLE / GUARDIAN_FULL_ROLE.
     * @dev Does not affect withdrawals or reward claims unless global pause is active.
     */
    function pauseDeposits() external onlyGuardianRole {
        if (_depositsPaused) revert BirdieswapStakingV1__DepositsAlreadyPaused();
        _depositsPaused = true;
        try i_event.emitStakingDepositsPaused(msg.sender) { } catch { }
    }

    /**
     * @notice Unpause deposits.
     * @custom:governance Only UNPAUSER_ROLE.
     */
    function unpauseDeposits() external onlyUnpauserRole {
        if (!_depositsPaused) revert BirdieswapStakingV1__DepositsNotPaused();
        _depositsPaused = false;
        try i_event.emitStakingDepositsUnpaused(msg.sender) { } catch { }
    }

    /**
     * @notice Pause only withdrawals.
     * @custom:governance Only MANAGER_ROLE.
     * @dev Does not affect deposits or reward claims unless global pause is active.
     */
    function pauseWithdrawals() external onlyManagerRole {
        if (_withdrawalsPaused) revert BirdieswapStakingV1__WithdrawalsAlreadyPaused();
        _withdrawalsPaused = true;
        try i_event.emitStakingWithdrawalsPaused(msg.sender) { } catch { }
    }

    /**
     * @notice Unpause withdrawals.
     * @custom:governance Only UNPAUSER_ROLE.
     */
    function unpauseWithdrawals() external onlyUnpauserRole {
        if (!_withdrawalsPaused) revert BirdieswapStakingV1__WithdrawalsNotPaused();
        _withdrawalsPaused = false;
        try i_event.emitStakingWithdrawalsUnpaused(msg.sender) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── Read-Only Helpers ─────────────────────
    /// @dev Reverts if the reward index is out of bounds.
    function _assertValidIndex(uint256 i) internal view {
        if (i >= rewards.length) revert BirdieswapStakingV1__InvalidRewardIndex();
    }

    /**
     * @notice Returns the last timestamp for which rewards are applicable (min of now and periodFinish).
     * @param _rewardIndex Index of the reward token.
     */
    function _lastTimeRewardApplicable(uint256 _rewardIndex) internal view returns (uint256) {
        RewardInfo storage rewardInfo = rewards[_rewardIndex];
        return (block.timestamp < rewardInfo.periodFinish ? block.timestamp : rewardInfo.periodFinish);
    }

    /**
     * @notice Gets the current reward-per-token value for a reward index.
     * @param _rewardIndex Index of the reward token in `rewards`.
     * @return rewardPerToken Current cumulative reward per staked token (scaled by i_precision).
     * @dev If `s_totalSupply == 0`, returns the stored value.
     * @dev Uses `_lastTimeRewardApplicable` to cap accrual at `periodFinish`.
     */
    function _getRewardPerToken(uint256 _rewardIndex) internal view returns (uint256 rewardPerToken) {
        _assertValidIndex(_rewardIndex);

        RewardInfo storage rewardInfo = rewards[_rewardIndex];
        if (s_totalSupply == 0) return rewardInfo.rewardPerTokenStored;

        uint256 lastTime = _lastTimeRewardApplicable(_rewardIndex);
        if (lastTime <= rewardInfo.lastUpdate) return rewardInfo.rewardPerTokenStored;

        uint256 deltaTime = lastTime - rewardInfo.lastUpdate;
        uint256 increment = Math.mulDiv(deltaTime, rewardInfo.rewardSpeed * i_precision, s_totalSupply);
        return rewardInfo.rewardPerTokenStored + increment;
    }

    /// @dev Utility: wrap a single index in an array for unified update paths.
    function _singleIndex(uint256 _i) private pure returns (uint256[] memory) {
        uint256[] memory a = new uint256[](1);
        a[0] = _i;
        return a;
    }

    // ────────────────────── State Mutators ───────────────────────

    /**
     * @notice Efficiently updates reward accounting for one or multiple reward indices.
     * @dev
     * - If `_rewardIndices` is empty, updates all rewards.
     * - Otherwise, updates only the specified indices.
     * - Inlines rewardPerToken logic to avoid redundant calls and storage reads.
     * @param _userAddress   User address to accrue rewards for (zero to skip per-user accrual).
     * @param _rewardIndices Optional list of indices to update; pass empty to update all.
     */
    function _updateRewards(address _userAddress, uint256[] memory _rewardIndices) internal {
        uint256 length = rewards.length;
        uint256 count = _rewardIndices.length;
        bool updateAll = (count == 0);

        for (uint256 i; i < (updateAll ? length : count);) {
            uint256 index = updateAll ? i : _rewardIndices[i];
            if (index >= length) revert BirdieswapStakingV1__InvalidRewardIndex();

            RewardInfo storage rewardInfo = rewards[index];
            uint256 totalSupply = s_totalSupply;

            // Inline rewardPerToken logic
            uint256 rpt = rewardInfo.rewardPerTokenStored;
            if (totalSupply != 0) {
                uint256 lastTime = (block.timestamp < rewardInfo.periodFinish) ? block.timestamp : rewardInfo.periodFinish;
                if (lastTime > rewardInfo.lastUpdate) {
                    uint256 deltaTime = lastTime - rewardInfo.lastUpdate;
                    uint256 increment = Math.mulDiv(deltaTime, rewardInfo.rewardSpeed * i_precision, totalSupply);
                    rpt += increment;
                }
            }

            // Write back global snapshot
            rewardInfo.rewardPerTokenStored = rpt;
            rewardInfo.lastUpdate = (block.timestamp < rewardInfo.periodFinish) ? block.timestamp : rewardInfo.periodFinish;

            // Per-user accrual
            if (_userAddress != address(0)) {
                uint256 balance = balanceOf[_userAddress];
                uint256 paid = userRewardPerTokenPaid[_userAddress][index];
                uint256 pending = Math.mulDiv(balance, (rpt - paid), i_precision);
                userRewardAccrued[_userAddress][index] += pending;
                userRewardPerTokenPaid[_userAddress][index] = rpt;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Deposit staking tokens (no reward claim).
     * @param _stakeAmount Amount to deposit.
     */
    function _deposit(uint256 _stakeAmount) private nonReentrantInternal {
        if (_stakeAmount == 0) revert BirdieswapStakingV1__InvalidAmount();

        // Update accounting then mutate balances (CEI)
        uint256[] memory empty;
        _updateRewards(msg.sender, empty);

        uint256 newSupply = s_totalSupply + _stakeAmount;
        if (newSupply > i_maxTotalSupply) revert BirdieswapStakingV1__ExceededMaxCap();
        s_totalSupply = newSupply;
        balanceOf[msg.sender] += _stakeAmount;

        // Effects complete → interactions
        SafeERC20.safeTransferFrom(i_stakingToken, msg.sender, address(this), _stakeAmount);
        try i_event.emitStakingDeposit(msg.sender, _stakeAmount, address(i_stakingToken)) { } catch { }
    }

    /**
     * @notice Withdraw staked tokens (no reward claim).
     * @param _withdrawAmount Amount to withdraw.
     * @dev Rewards are snapshotted before balance reduction to preserve accrual.
     */
    function _withdraw(uint256 _withdrawAmount) private nonReentrantInternal {
        if (_withdrawAmount == 0) revert BirdieswapStakingV1__InvalidAmount();
        if (balanceOf[msg.sender] < _withdrawAmount) revert BirdieswapStakingV1__InsufficientBalance();

        // Update accounting then mutate balances (CEI)
        uint256[] memory empty;
        _updateRewards(msg.sender, empty);

        balanceOf[msg.sender] -= _withdrawAmount;
        s_totalSupply -= _withdrawAmount;

        // Effects complete → interactions
        SafeERC20.safeTransfer(i_stakingToken, msg.sender, _withdrawAmount);
        try i_event.emitStakingWithdraw(msg.sender, _withdrawAmount, address(i_stakingToken)) { } catch { }
    }

    /**
     * @notice Handles reward transfers, partial payment, and events.
     * @dev Safe against underpayment; any remaining accrual stays recorded for future claims.
     */
    function _payoutReward(address _user, uint256 _rewardIndex, uint256 _accrued) private nonReentrantInternal {
        RewardInfo storage info = rewards[_rewardIndex];
        IERC20 token = info.rewardToken;

        uint256 balance = token.balanceOf(address(this));
        uint256 rewardAmount = _accrued < balance ? _accrued : balance;

        if (rewardAmount > 0) {
            userRewardAccrued[_user][_rewardIndex] = _accrued - rewardAmount;
            SafeERC20.safeTransfer(token, _user, rewardAmount);
            try i_event.emitRewardPaid(_user, rewardAmount, address(token)) { } catch { }
            if (rewardAmount < _accrued) {
                try i_event.emitRewardPartiallyPaid(_user, rewardAmount, address(token), _accrued - rewardAmount) { } catch { }
            }
        }
    }

    /**
     * @notice Claims all accrued rewards for a user across all reward tokens.
     * @dev Assumes caller’s rewards were updated beforehand for accuracy.
     */
    function _claimAllTo(address _recipient) private {
        uint256 length = rewards.length;
        for (uint256 i = 0; i < length;) {
            uint256 accrued = userRewardAccrued[_recipient][i];
            if (accrued != 0) _payoutReward(_recipient, i, accrued);
            unchecked {
                ++i;
            }
        }
        try i_event.emitClaimAll(_recipient, length) { } catch { }
    }
}
/*//////////////////////////////////////////////////////////////
                        END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant Staked-supply conservation: s_totalSupply equals the sum of all users' balanceOf.
/// @custom:invariant For every reward index i, rewards[i].rewardPerTokenStored is monotonically non-decreasing and cannot increase after
///                   rewards[i].periodFinish.
/// @custom:invariant For all users u and reward indices i: userRewardPerTokenPaid[u][i] <= rewards[i].rewardPerTokenStored, and
///                   userRewardAccrued[u][i] is never negative (payouts only decrease it).
