// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title IBirdieswapStakingV1
 * @notice Interface for the Birdieswap Multi-Reward Staking contract (V1).
 * @dev
 * - Supports one staking token and up to MAX_REWARD_TOKENS concurrent reward tokens.
 * - Intended for integration by frontends, routers, analytics, and vaults.
 */
interface IBirdieswapStakingV1 {
    /*//////////////////////////////////////////////////////////////
                           CORE USER FLOWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit staking tokens without claiming rewards.
     * @param _stakeAmount Amount of tokens to deposit.
     * @dev Increases user balance and total supply.
     */
    function deposit(uint256 _stakeAmount) external;

    /**
     * @notice Deposit staking tokens and claim all available rewards.
     * @param _stakeAmount Amount of tokens to deposit.
     * @dev Equivalent to deposit() + claimAll().
     */
    function depositAndClaimAll(uint256 _stakeAmount) external;

    /**
     * @notice Withdraw previously staked tokens without claiming rewards.
     * @param _withdrawAmount Amount of tokens to withdraw.
     * @dev Preserves unclaimed reward accrual.
     */
    function withdraw(uint256 _withdrawAmount) external;

    /**
     * @notice Withdraw staked tokens and claim all rewards in a single transaction.
     * @param _withdrawAmount Amount of tokens to withdraw.
     */
    function withdrawAndClaimAll(uint256 _withdrawAmount) external;

    /**
     * @notice Claim rewards for a specific reward token.
     * @param _rewardIndex Reward token index to claim.
     * @dev Updates accounting and pays out available amount (partial if insufficient balance).
     */
    function claim(uint256 _rewardIndex) external;

    /**
     * @notice Claim multiple reward tokens in a single transaction.
     * @param _rewardIndices List of reward token indices to claim.
     * @dev Reverts on duplicate or invalid indices.
     */
    function claimMany(uint256[] calldata _rewardIndices) external;

    /**
     * @notice Claim all available rewards across all reward tokens.
     * @dev Emits multiple RewardPaid events and one ClaimAll event.
     */
    function claimAll() external;

    /**
     * @notice Withdraw all staked tokens immediately, forfeiting all accrued rewards.
     * @dev Designed for self-rescue; wipes all user reward states.
     */
    function emergencyWithdraw() external;

    /*//////////////////////////////////////////////////////////////
                           READ-ONLY VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total number of configured reward tokens.
     * @return count Number of active reward schedules.
     */
    function getRewardCount() external view returns (uint256 count);

    /**
     * @notice View helper to read pending rewards for selected indices.
     * @param _account User address to query.
     * @param _rewardIndices Reward indices to query.
     * @return pendingRewards Pending reward amounts in the same order as indices.
     */
    function getPendingRewards(address _account, uint256[] calldata _rewardIndices) external view returns (uint256[] memory pendingRewards);

    /**
     * @notice Read reward schedule metadata for a given index.
     * @param _rewardIndex Reward index.
     * @return token Reward token address.
     * @return rewardPerTokenStored Cumulative reward per staked token (PRECISION-scaled).
     * @return lastUpdate Last reward update timestamp.
     * @return rewardSpeed Emission rate in tokens/sec.
     * @return periodFinish Timestamp when the current emission schedule ends.
     */
    function getRewardInfo(
        uint256 _rewardIndex
    ) external view returns (address token, uint256 rewardPerTokenStored, uint256 lastUpdate, uint256 rewardSpeed, uint256 periodFinish);

    /**
     * @notice Returns remaining emission amount for an ongoing reward schedule.
     * @param _rewardIndex Reward index.
     * @return remaining Remaining tokens to be distributed.
     */
    function getTotalOutstanding(uint256 _rewardIndex) external view returns (uint256 remaining);

    /**
     * @notice Return staking token address.
     */
    function getStakingToken() external view returns (address);

    /**
     * @notice Return total staked token amount.
     */
    function getTotalSupply() external view returns (uint256);

    /**
     * @notice Return all reward token addresses.
     * @return tokens Array of reward token addresses.
     */
    function getAllRewardTokens() external view returns (address[] memory tokens);

    /*//////////////////////////////////////////////////////////////
                               GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whitelist or unwhitelist a reward token.
     * @param _tokenAddress ERC20 token address.
     * @param _allowed True to whitelist, false to unwhitelist.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setRewardTokenWhitelist(address _tokenAddress, bool _allowed) external;

    /**
     * @notice Add a new reward token (must be whitelisted).
     * @param _rewardToken ERC20 token address.
     * @dev Only callable by POOL_MANAGER_ROLE.
     */
    function addRewardToken(address _rewardToken) external;

    /**
     * @notice Fund or extend a reward schedule.
     * @param _rewardIndex Reward index.
     * @param _rewardAmount Funding amount.
     * @param _duration Emission duration in seconds.
     * @dev Only callable by DISTRIBUTOR_ROLE.
     */
    function fundReward(uint256 _rewardIndex, uint256 _rewardAmount, uint256 _duration) external;

    /**
     * @notice Rescue a non-staking, non-reward ERC20 token accidentally sent to the contract.
     * @param _tokenAddress Token address to rescue.
     * @param _receiverAddress Recipient address.
     * @param _tokenAmount Amount to transfer.
     * @dev Only callable by POOL_MANAGER_ROLE.
     */
    function rescueERC20(address _tokenAddress, address _receiverAddress, uint256 _tokenAmount) external;

    /*//////////////////////////////////////////////////////////////
                               PAUSING
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause all contract functions (global pause).
    function pause() external;

    /// @notice Unpause all contract functions (global).
    function unpause() external;

    /// @notice Pause deposits only.
    function pauseDeposits() external;

    /// @notice Unpause deposits only.
    function unpauseDeposits() external;

    /// @notice Pause withdrawals only.
    function pauseWithdrawals() external;

    /// @notice Unpause withdrawals only.
    function unpauseWithdrawals() external;

    /// @notice Returns true if deposits are paused.
    function depositsPaused() external view returns (bool);

    /// @notice Returns true if withdrawals are paused.
    function withdrawalsPaused() external view returns (bool);
}
