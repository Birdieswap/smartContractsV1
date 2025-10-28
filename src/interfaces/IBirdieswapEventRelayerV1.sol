// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title  IBirdieswapEventRelayerV1
 * @author Birdieswap Team
 * @notice Interface for BirdieswapEventRelayerV1 — unified event relay hub.
 * @dev    Each module (Router, Vaults, Strategies, Staking, Wrapper, etc.)
 *         calls its respective emit functions to propagate standardized events.
 */
interface IBirdieswapEventRelayerV1 {
    /*//////////////////////////////////////////////////////////////
                                  ENUM
    //////////////////////////////////////////////////////////////*/
    enum SingleStrategyValidationReason {
        NONE, // 0 — success
        ZERO_ADDRESS, // 1
        SAME_AS_EXISTING, // 2
        NOT_CONTRACT, // 3
        VAULT_MISMATCH, // 4
        UNDERLYING_MISMATCH, // 5
        PROOF_TOKEN_MISMATCH, // 6
        DEPOSIT_PREVIEW_FAIL, // 7
        WITHDRAW_PREVIEW_FAIL, // 8
        MATH_INCONSISTENT // 9

    }
    enum DualStrategyValidationReason {
        NONE, // 0 — success
        ZERO_ADDRESS, // 1
        SAME_AS_EXISTING, // 2
        NOT_CONTRACT, // 3
        VAULT_MISMATCH, // 4
        ASSET_MISMATCH, // 5
        INVALID_POOL // 6

    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────────── Common ───────────────────────────
    event EventRelayerUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);
    event StorageUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);
    event RouterUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);

    /*//////////////////////////////////////////////////////////////
                        WRAPPER EVENTS
    //////////////////////////////////////////////////////////////*/
    event SingleDepositETH(address indexed user, uint256 ethAmount, uint256 bTokenAmount);
    event SingleRedeemETH(address indexed user, address indexed bToken, uint256 wethAmount);
    event DualDepositWithETH(address indexed user, uint256 ethAmount, address tokenAddress, uint256 tokenAmount, uint256 blpTokenAmount);
    event DualRedeemToETH(
        address indexed user,
        address indexed blpToken,
        address token0Address,
        uint256 token0Amount,
        address token1Address,
        uint256 token1Amount
    );
    event SwapFromETH(address indexed user, uint256 ethIn, address tokenOut, uint256 amountOut);
    event SwapToETH(address indexed user, address tokenIn, uint256 tokenInAmount, uint256 ethOut);

    /*//////////////////////////////////////////////////////////////
                        ROUTER EVENTS
    //////////////////////////////////////////////////////////////*/
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
    event GlobalPaused(address account);
    event GlobalUnpaused(address account);
    event DepositsPaused(address account);
    event DepositsUnpaused(address account);
    event SwapsPaused(address account);
    event SwapsUnpaused(address account);
    event SingleVaultMappingSet(address indexed underlyingTokenAddress, address indexed bTokenAddressOld, address indexed bTokenAddressNew);
    event DualVaultMappingSet(
        address indexed bToken0Address, address indexed bToken1Address, address blpTokenAddressOld, address indexed blpTokenAddressNew
    );
    event RewardTokenWhitelistSet(address indexed tokenAddress, bool allowed, address indexed byAddress);
    event BirdieswapContractListSet(address indexed contractAddress, bool isTrue, address indexed byAddress);
    event BirdieswapEventRelayerAddressSet(address indexed contractAddress, address indexed byAddress);
    event BirdieswapRoleRouterAddressSet(address indexed contractAddress, address indexed byAddress);
    event BirdieswapFeeCollectingAddressSet(address indexed collectingAddress, address indexed byAddress);

    /*//////////////////////////////////////////////////////////////
                        STAKING EVENTS
    //////////////////////////////////////////////////////////////*/
    event StakingDeposit(address indexed userAddress, uint256 amount, address indexed tokenAddress);
    event StakingWithdraw(address indexed userAddress, uint256 amount, address indexed tokenAddress);
    event EmergencyWithdraw(address indexed userAddress, uint256 amount, address indexed tokenAddress);
    event RewardsForfeited(address indexed userAddress, uint256[] indices, uint256[] amounts);
    event RewardPaid(address indexed userAddress, uint256 amount, address indexed tokenAddress);
    event RewardPartiallyPaid(address indexed userAddress, uint256 amount, address indexed tokenAddress, uint256 stillAccruedAmount);
    event ClaimAll(address indexed userAddress, uint256 tokenTypesClaimed);
    event RewardTokenAdded(uint256 indexed rewardIndex, address indexed tokenAddress);
    event RewardFunded(
        uint256 indexed rewardIndex,
        uint256 rewardAmount,
        uint256 duration,
        address fromAddress,
        uint256 leftover,
        uint256 totalFunding,
        uint256 newRate
    );
    event ERC20RescuedFromStaking(address indexed tokenAddress, uint256 amount, address indexed receiverAddress, address byAddress);
    event StakingGlobalPaused(address byAddress);
    event StakingGlobalUnpaused(address byAddress);
    event StakingDepositsPaused(address byAddress);
    event StakingDepositsUnpaused(address byAddress);
    event StakingWithdrawalsPaused(address byAddress);
    event StakingWithdrawalsUnpaused(address byAddress);

    /*//////////////////////////////////////////////////////////////
                        SINGLE VAULT / STRATEGY EVENTS
    //////////////////////////////////////////////////////////////*/
    event SingleDeposit(
        address indexed receiver,
        address indexed underlyingTokenAddress,
        uint256 underlyingTokenAmount,
        address indexed bTokenAddress,
        uint256 bTokenAmount
    );
    event SingleWithdraw(
        address indexed receiver,
        address indexed bTokenAddress,
        uint256 bTokenAmount,
        address indexed underlyingTokenAddress,
        uint256 underlyingTokenAmount
    );
    event ERC20RescuedFromSingleVault(address indexed tokenAddress, uint256 amount, address indexed receiverAddress, address byAddress);
    event SingleStrategyProposed(address indexed proposedStrategy);
    event SingleStrategyAccepted(address indexed oldStrategy, address indexed newStrategy);
    event SingleStrategyValidationFailed(address indexed proposedStrategy, uint8 reason);
    event SingleEmergencyExitTriggered(address indexed strategy, uint256 exitAmount);
    event SingleDepositsPaused(address account);
    event SingleDepositsUnpaused(address account);
    event SingleHardWork(address indexed claimedTokenAddress, uint256 claimedTokenAmount, uint256 autoCompoundedAmount);

    /*//////////////////////////////////////////////////////////////
                        DUAL VAULT / STRATEGY EVENTS
    //////////////////////////////////////////////////////////////*/
    event DualDeposit(
        address indexed owner,
        address bToken0Address,
        uint256 bToken0Amount,
        address bToken1Address,
        uint256 bToken1Amount,
        address blpTokenAddress,
        uint256 blpTokenAmount
    );
    event DualWithdraw(
        address indexed caller,
        address blpTokenAddress,
        uint256 blpTokenAmount,
        address bToken0Address,
        uint256 bToken0Amount,
        address bToken1Address,
        uint256 bToken1Amount
    );
    event NFTReceived(address operator, address from, uint256 tokenId, bytes data);
    event MintNotSupported(address sender, uint256 shares, address receiver);
    event WithdrawNotSupported(address sender, uint256 assets, address receiver, address owner);
    event MustDepositTwoTokens(address sender, uint256 assets, address receiver);
    event MustRedeemProperly(address sender, uint256 shares, address receiver, address owner);
    event ERC20RescuedFromDualVault(address indexed tokenAddress, uint256 amount, address indexed receiverAddress, address byAddress);
    event DualStrategyProposed(address indexed proposedStrategy);
    event DualStrategyAccepted(address indexed oldStrategy, address indexed newStrategy);
    event DualStrategyValidationFailed(address indexed proposedStrategy, uint8 reason);
    event DualEmergencyExitTriggered(address indexed strategy, uint256 exitAmount0, uint256 exitAmount1);
    event DualHardWork(uint256 liquidity, uint256 bToken0, uint256 bToken1, uint256 operationWETHFee);
    event DualEmergencyExit(uint256 bToken0Amount, uint256 bToken1Amount);

    /*//////////////////////////////////////////////////////////////
                        RELAY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // ─────────── DualStrategy
    function emitDualHardWork(uint256 liquidity, uint256 bToken0, uint256 bToken1, uint256 operationWETHFee) external;
    function emitDualEmergencyExit(uint256 bToken0Amount, uint256 bToken1Amount) external;

    // ─────────── DualVault
    function emitDualDeposit(
        address owner,
        address bToken0Address,
        uint256 bToken0Amount,
        address bToken1Address,
        uint256 bToken1Amount,
        address blpTokenAddress,
        uint256 blpTokenAmount
    ) external;
    function emitDualWithdraw(
        address caller,
        address blpTokenAddress,
        uint256 blpTokenAmount,
        address bToken0Address,
        uint256 bToken0Amount,
        address bToken1Address,
        uint256 bToken1Amount
    ) external;
    function emitNFTReceived(address operator, address from, uint256 tokenId, bytes calldata data) external;
    function emitMintNotSupported(address sender, uint256 shares, address receiver) external;
    function emitWithdrawNotSupported(address sender, uint256 assets, address receiver, address owner) external;
    function emitMustDepositTwoTokens(address sender, uint256 assets, address receiver) external;
    function emitMustRedeemProperly(address sender, uint256 shares, address receiver, address owner) external;
    function emitERC20RescuedFromDualVault(address tokenAddress, uint256 amount, address receiverAddress, address byAddress) external;
    function emitDualStrategyProposed(address proposedStrategy) external;
    function emitDualStrategyAccepted(address oldStrategy, address newStrategy) external;
    function emitDualStrategyValidationFailed(address proposedStrategy, uint8 reason) external;
    function emitDualEmergencyExitTriggered(address strategy, uint256 exitAmount0, uint256 exitAmount1) external;

    // ─────────── SingleStrategy
    function emitSingleHardWork(address claimedTokenAddress, uint256 claimedTokenAmount, uint256 autoCompoundedAmount) external;

    // ─────────── SingleVault
    function emitSingleDeposit(
        address receiver,
        address underlyingTokenAddress,
        uint256 underlyingTokenAmount,
        address bTokenAddress,
        uint256 bTokenAmount
    ) external;
    function emitSingleWithdraw(
        address receiver,
        address bTokenAddress,
        uint256 bTokenAmount,
        address underlyingTokenAddress,
        uint256 underlyingTokenAmount
    ) external;
    function emitERC20RescuedFromSingleVault(address tokenAddress, uint256 amount, address receiverAddress, address byAddress) external;
    function emitSingleStrategyProposed(address proposedStrategy) external;
    function emitSingleStrategyAccepted(address oldStrategy, address newStrategy) external;
    function emitSingleStrategyValidationFailed(address proposedStrategy, uint8 reason) external;
    function emitSingleEmergencyExitTriggered(address strategy, uint256 exitAmount) external;
    function emitSingleDepositsPaused(address account) external;
    function emitSingleDepositsUnpaused(address account) external;

    // ─────────── Staking
    function emitStakingDeposit(address userAddress, uint256 amount, address tokenAddress) external;
    function emitStakingWithdraw(address userAddress, uint256 amount, address tokenAddress) external;
    function emitEmergencyWithdraw(address userAddress, uint256 amount, address tokenAddress) external;
    function emitRewardsForfeited(address userAddress, uint256[] calldata indices, uint256[] calldata amounts) external;
    function emitRewardPaid(address userAddress, uint256 amount, address tokenAddress) external;
    function emitRewardPartiallyPaid(address userAddress, uint256 amount, address tokenAddress, uint256 stillAccruedAmount) external;
    function emitClaimAll(address userAddress, uint256 tokenTypesClaimed) external;
    function emitRewardTokenAdded(uint256 rewardIndex, address tokenAddress) external;
    function emitRewardFunded(
        uint256 rewardIndex,
        uint256 rewardAmount,
        uint256 duration,
        address fromAddress,
        uint256 leftover,
        uint256 totalFunding,
        uint256 newRate
    ) external;
    function emitERC20RescuedFromStaking(address tokenAddress, uint256 amount, address receiverAddress, address byAddress) external;
    function emitStakingGlobalPaused(address byAddress) external;
    function emitStakingGlobalUnpaused(address byAddress) external;
    function emitStakingDepositsPaused(address byAddress) external;
    function emitStakingDepositsUnpaused(address byAddress) external;
    function emitStakingWithdrawalsPaused(address byAddress) external;
    function emitStakingWithdrawalsUnpaused(address byAddress) external;

    // ─────────── Storage
    function emitStorageUpgraded(address oldImplementation, address newImplementation, address upgrader) external;

    // ─────────── Wrapper
    function emitSingleDepositETH(address user, uint256 ethAmount, uint256 bTokenAmount) external;
    function emitSingleRedeemETH(address user, address bToken, uint256 wethAmount) external;
    function emitDualDepositWithETH(address user, uint256 ethAmount, address tokenAddress, uint256 tokenAmount, uint256 blpTokenAmount)
        external;
    function emitDualRedeemToETH(
        address user,
        address blpToken,
        address token0Address,
        uint256 token0Amount,
        address token1Address,
        uint256 token1Amount
    ) external;
    function emitSwapFromETH(address user, uint256 ethIn, address tokenOut, uint256 amountOut) external;
    function emitSwapToETH(address user, address tokenIn, uint256 tokenInAmount, uint256 ethOut) external;

    // ─────────── Router
    function emitSwap(
        address user,
        address caller,
        address tokenIn,
        uint24 feeTier,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address referrerAddress
    ) external;
    function emitGlobalPaused(address account) external;
    function emitGlobalUnpaused(address account) external;
    function emitDepositsPaused(address account) external;
    function emitDepositsUnpaused(address account) external;
    function emitSwapsPaused(address account) external;
    function emitSwapsUnpaused(address account) external;
    function emitSingleVaultMappingSet(address underlyingTokenAddress, address bTokenAddressOld, address bTokenAddressNew) external;
    function emitDualVaultMappingSet(address bToken0Address, address bToken1Address, address blpTokenAddressOld, address blpTokenAddressNew)
        external;
    function emitRouterUpgraded(address oldImplementation, address newImplementation, address upgrader) external;
    function emitRewardTokenWhitelistSet(address tokenAddress, bool allowed, address byAddress) external;
    function emitBirdieswapContractListSet(address contractAddress, bool isTrue, address byAddress) external;
    function emitBirdieswapEventRelayerAddressSet(address contractAddress, address byAddress) external;
    function emitBirdieswapRoleRouterAddressSet(address contractAddress, address byAddress) external;
    function emitBirdieswapFeeCollectingAddressSet(address collectingAddress, address byAddress) external;
    function emitRouterConfigAddressSet(address contractAddress, address byAddress) external;

    // ─────────── Event Relayer
    function getVersion() external pure returns (string memory);
}
