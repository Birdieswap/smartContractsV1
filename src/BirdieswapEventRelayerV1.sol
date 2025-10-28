// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { Initializable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils } from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

// Birdieswap V1 modules
import { BirdieswapRoleSignaturesV1 } from "./BirdieswapRoleSignaturesV1.sol";
import { IBirdieswapStorageV1 } from "./interfaces/IBirdieswapStorageV1.sol";
import { IBirdieswapRoleRouterV1 } from "./interfaces/IBirdieswapRoleRouterV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapEventRelayerV1
 * @author Birdieswap Team
 * @notice Centralized event relayer that aggregates and re-emits all protocol-wide events.
 * @dev    Only registered official modules (recorded in BirdieswapStorageV1) can emit through this relayer.
 *         Off-chain indexers can monitor this contract to capture all protocol-level activity in one stream.
 * @custom:security Only modules registered in BirdieswapStorageV1 can emit through this relayer.
 */
abstract contract BirdieswapEventRelayerV1 is Initializable, UUPSUpgradeable, BirdieswapRoleSignaturesV1 {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BirdieswapEventRelayerV1__UnauthorizedAccess();
    error BirdieswapEventRelayerV1__InvalidAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapEventRelayerV1";

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Global storage reference
    IBirdieswapStorageV1 private s_storage;

    // Role router contract
    IBirdieswapRoleRouterV1 private s_role;

    /**
     * @dev Reserved storage space to allow layout changes in future upgrades.
     *      New variables must be added above this line. This gap ensures that
     *      upgrading the contract will not cause storage collisions.
     */
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                MODIFIER
    //////////////////////////////////////////////////////////////*/

    /// @dev Restrict to modules registered in BirdieswapStorageV1.
    modifier onlyBirdieswap() {
        if (!(s_storage.isBirdieswap(msg.sender))) revert BirdieswapEventRelayerV1__UnauthorizedAccess();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION & UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes contract references for storage and role router.
     */
    function initialize(address storageAddress_) public initializer {
        s_storage = IBirdieswapStorageV1(storageAddress_);
        address roleRouterAddress = s_storage.s_roleRouterAddress();
        s_role = IBirdieswapRoleRouterV1(roleRouterAddress);
    }

    /// @notice Return the contract version.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /// @dev UUPS authorization: only UPGRADER_ROLE() can upgrade implementation.
    function _authorizeUpgrade(address newImplementation) internal override {
        if (!s_role.hasRoleGlobal(UPGRADER_ROLE, msg.sender)) revert BirdieswapEventRelayerV1__UnauthorizedAccess();

        // Emit event for governance transparency
        emit EventRelayerUpgraded(ERC1967Utils.getImplementation(), newImplementation, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        EVENTS (BirdieswapStorageV1)
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when the storage implementation is upgraded.
    event StorageUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);

    /*//////////////////////////////////////////////////////////////
                        EVENTS (BirdieswapRouterV1)
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── User Interactions ─────────────────────
    /**
     * @notice Emitted after a swap of underlying-in → underlying-out is completed.
     * @dev    `user` uses tx.origin intentionally to reflect the end user even when a wrapper/relayer calls the router.
     *         `caller` uses _msgSender() to keep richer context. `referrerAddress` is for analytics/attribution only.
     *         This event is not used for access control.
     */
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

    // ──────────────────── Governance / Admin ─────────────────────
    // Pause / Unpause Management
    event GlobalPaused(address account);
    event GlobalUnpaused(address account);
    event DepositsPaused(address account);
    event DepositsUnpaused(address account);
    event SwapsPaused(address account);
    event SwapsUnpaused(address account);

    // Vault Mapping Management
    /// @notice Underlying ↔ Single vault mapping set
    event SingleVaultMappingSet(address indexed underlyingTokenAddress, address indexed bTokenAddressOld, address indexed bTokenAddressNew);

    /// @notice Ordered (bToken0 < bToken1) ↔ Dual vault mapping set
    event DualVaultMappingSet(
        address indexed bToken0Address, address indexed bToken1Address, address blpTokenAddressOld, address indexed blpTokenAddressNew
    );

    // Contract & Whitelist Management
    /// @notice Emitted when admin toggles whitelist status of a reward token.
    event RewardTokenWhitelistSet(address indexed tokenAddress, bool allowed, address indexed byAddress);

    /// @notice Emitted when a contract address is added/removed from the authorized Birdieswap list.
    event BirdieswapContractListSet(address indexed contractAddress, bool isTrue, address indexed byAddress);

    /// @notice Emitted when the official Event Relayer contract address is updated.
    event BirdieswapEventRelayerAddressSet(address indexed contractAddress, address indexed byAddress);

    /// @notice Emitted when the official Role Router contract address is updated.
    event BirdieswapRoleRouterAddressSet(address indexed contractAddress, address indexed byAddress);

    /// @notice Emitted when the official Fee Collecting address is updated.
    event BirdieswapFeeCollectingAddressSet(address indexed collectingAddress, address indexed byAddress);

    // Upgrade Events
    /// @notice Emitted when the router implementation is upgraded.
    event RouterUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);

    /// @notice Emitted when the router's config address is updated.
    event RouterConfigAddressSet(address configAddress, address indexed byAddress);

    /*//////////////////////////////////////////////////////////////
                        EVENTS (BirdieswapWrapperV1)
    //////////////////////////////////////////////////////////////*/
    // Wrapper-centric UX events (ETH entry/exit + swaps).

    // ──────────────── Single Vault (ETH ↔ bToken) ────────────────
    /// @notice Emitted when a user deposits ETH through the wrapper to mint a bToken.
    event SingleDepositETH(address indexed user, uint256 ethAmount, uint256 bTokenAmount);

    /// @notice Emitted when a user redeems bTokens through the wrapper to receive WETH.
    event SingleRedeemETH(address indexed user, address indexed bToken, uint256 wethAmount);

    // ──────────── Dual Vault (ETH + Token ↔ blpToken) ────────────
    /// @notice Emitted when a user deposits ETH + ERC20 token through the wrapper to mint a blpToken.
    event DualDepositWithETH(address indexed user, uint256 ethAmount, address tokenAddress, uint256 tokenAmount, uint256 blpTokenAmount);

    /// @notice Emitted when a user redeems a blpToken through the wrapper and receives ETH + ERC20 tokens.
    event DualRedeemToETH(
        address indexed user,
        address indexed blpToken,
        address token0Address,
        uint256 token0Amount,
        address token1Address,
        uint256 token1Amount
    );

    // ──────────────────── Swaps (ETH ↔ Token) ────────────────────
    /// @notice Emitted when a user swaps ETH for a token through the wrapper.
    event SwapFromETH(address indexed user, uint256 ethIn, address tokenOut, uint256 amountOut);

    /// @notice Emitted when a user swaps a token for ETH through the wrapper.
    event SwapToETH(address indexed user, address tokenIn, uint256 tokenInAmount, uint256 ethOut);

    /*//////////////////////////////////////////////////////////////
                    EVENTS (BirdieswapSingleVaultV1)
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── ENUM ─────────────────────────────
    /// @notice Validation failure reasons for proposed SingleStrategy updates.
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

    // ───────────────────── User Interactions ─────────────────────
    /// @notice Emitted on every user deposit (vanilla → Birdieswap bToken).
    event SingleDeposit(
        address indexed receiver,
        address indexed underlyingTokenAddress,
        uint256 underlyingTokenAmount,
        address indexed bTokenAddress,
        uint256 bTokenAmount
    );

    /// @notice Emitted on every user withdrawal (bToken → vanilla).
    /// @dev Parameter order mirrors actual flow direction (deposit: underlying→bToken, withdraw: bToken→underlying).
    event SingleWithdraw(
        address indexed receiver,
        address indexed bTokenAddress,
        uint256 bTokenAmount,
        address indexed underlyingTokenAddress,
        uint256 underlyingTokenAmount
    );

    // ────────────── Governance / Strategy Lifecycle ──────────────
    /// @notice Emitted when a new strategy is proposed by governance (TimelockController).
    event SingleStrategyProposed(address indexed proposedStrategy);

    /// @notice Emitted when governance accepts and activates a new strategy contract.
    /// @dev Integrators can treat this as the “vault ready” signal post-bootstrap.
    event SingleStrategyAccepted(address indexed oldStrategy, address indexed newStrategy);

    /// @notice Emitted when the proposed strategy fails validation checks.
    event SingleStrategyValidationFailed(address indexed proposedStrategy, SingleStrategyValidationReason reason);

    /// @notice Emitted when governance executes an emergency exit on the current strategy.
    event SingleEmergencyExitTriggered(address indexed strategy, uint256 exitAmount);

    /// @notice Emitted when a non-staking, non-reward ERC20 is rescued by governance.
    event ERC20RescuedFromSingleVault(address indexed tokenAddress, uint256 amount, address indexed receiverAddress, address byAddress);

    // ──────────────── Pause / Unpause Management ─────────────────
    /// @notice Emitted when deposits (and swaps) are paused by governance.
    event SingleDepositsPaused(address account);

    /// @notice Emitted when deposits (and swaps) are unpaused by governance.
    event SingleDepositsUnpaused(address account);

    /*//////////////////////////////////////////////////////////////
                    EVENTS (BirdieswapSingleStrategyV1)
    //////////////////////////////////////////////////////////////*/

    // ──────────────────── Strategy Operations ────────────────────
    /// @notice Emitted when compounding or reward reinvestment occurs within the strategy.
    event SingleHardWork(address indexed claimedTokenAddress, uint256 claimedTokenAmount, uint256 autoCompoundedAmount);

    /*//////////////////////////////////////////////////////////////
                    EVENTS (BirdieswapDualVaultV1)
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── ENUM ─────────────────────────────
    /// @notice Validation failure reasons for proposed DualStrategy updates.
    enum DualStrategyValidationReason {
        ZERO_ADDRESS, // 0
        SAME_AS_EXISTING, // 1
        NOT_CONTRACT, // 2
        VAULT_MISMATCH, // 3
        ASSET_MISMATCH, // 4
        INVALID_POOL_ADDRESS // 5

    }

    // ───────────────────── User Interactions ─────────────────────
    /// @notice Emitted on every user deposit into the DualVault (bToken0 + bToken1 → blpToken).
    event DualDeposit(
        address indexed owner,
        address bToken0Address,
        uint256 bToken0Amount,
        address bToken1Address,
        uint256 bToken1Amount,
        address blpTokenAddress,
        uint256 blpTokenAmount
    );

    /// @notice Emitted on every user withdrawal from the DualVault (blpToken → bToken0 + bToken1).
    event DualWithdraw(
        address indexed caller,
        address blpTokenAddress,
        uint256 blpTokenAmount,
        address bToken0Address,
        uint256 bToken0Amount,
        address bToken1Address,
        uint256 bToken1Amount
    );

    // ─────────────── Token Custody & Compatibility ───────────────
    /// @notice Records custody of Uniswap V3 position NFTs held by the vault.
    event NFTReceived(address operator, address from, uint256 tokenId, bytes data);

    // ────────────── ERC-4626 Compatibility Notices ───────────────
    /// @notice Emitted when a single-asset mint() is attempted on this dual-asset vault.
    event MintNotSupported(address sender, uint256 shares, address receiver);

    /// @notice Emitted when a single-asset withdraw() is attempted on this dual-asset vault.
    event WithdrawNotSupported(address sender, uint256 assets, address receiver, address owner);

    /// @notice Emitted when a single-token deposit() call is attempted instead of a dual-token deposit.
    event MustDepositTwoTokens(address sender, uint256 assets, address receiver);

    /// @notice Emitted when a single-asset redeem() path is attempted instead of a proper dual redemption.
    event MustRedeemProperly(address sender, uint256 shares, address receiver, address owner);

    // ────────────── Governance / Strategy Lifecycle ──────────────
    /// @notice Emitted when a valid new strategy is proposed by governance.
    event DualStrategyProposed(address indexed proposedStrategy);

    /// @notice Emitted when governance activates a new strategy contract.
    /// @dev Integrators can treat this as the “vault ready” signal post-bootstrap.
    ///      The vault grants NFT and ERC20 approvals to `newStrategy` at this point.
    event DualStrategyAccepted(address indexed oldStrategy, address indexed newStrategy);

    /// @notice Emitted when a proposed or pending strategy fails validation checks.
    event DualStrategyValidationFailed(address indexed proposedStrategy, DualStrategyValidationReason reason);

    // ───────────────── Emergency & Safety Valves ─────────────────
    /// @notice Emitted when governance executes an emergency exit to reclaim all managed assets.
    event DualEmergencyExitTriggered(address indexed strategy, uint256 exitAmount0, uint256 exitAmount1);

    /// @notice Emitted when a non-core ERC20 is rescued by governance through {rescueERC20()}.
    event ERC20RescuedFromDualVault(address indexed tokenAddress, uint256 amount, address indexed receiverAddress, address byAddress);

    /*//////////////////////////////////////////////////////////////
                    EVENTS (BirdieswapDualStrategyV1)
    //////////////////////////////////////////////////////////////*/

    // ──────────────────── Strategy Operations ────────────────────
    /// @notice Emitted after a successful `doHardWork()` compounding cycle.
    event DualHardWork(uint256 liquidity, uint256 bToken0, uint256 bToken1, uint256 operationWETHFee);

    /// @notice Emitted when the strategy performs an emergency exit and returns funds to the DualVault.
    event DualEmergencyExit(uint256 bToken0Amount, uint256 bToken1Amount);

    /*//////////////////////////////////////////////////////////////
                        EVENTS (BirdieswapStakingV1)
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── User Interactions ─────────────────────
    /// @notice Emitted on deposit of staking tokens by a user.
    event StakingDeposit(address indexed userAddress, uint256 amount, address indexed tokenAddress);

    /// @notice Emitted on withdrawal of staking tokens by a user (rewards may or may not be claimed).
    event StakingWithdraw(address indexed userAddress, uint256 amount, address indexed tokenAddress);

    /// @notice Emitted when a user performs an emergency withdraw (all rewards forfeited).
    event EmergencyWithdraw(address indexed userAddress, uint256 amount, address indexed tokenAddress);

    /// @notice Emitted when a user explicitly forfeits unclaimed rewards (e.g., via emergencyWithdraw).
    event RewardsForfeited(address indexed userAddress, uint256[] indices, uint256[] amounts);

    /// @notice Emitted whenever rewards are paid out in full for a specific reward token.
    event RewardPaid(address indexed userAddress, uint256 amount, address indexed tokenAddress);

    /// @notice Emitted when only a partial reward can be paid due to insufficient contract balance.
    event RewardPartiallyPaid(address indexed userAddress, uint256 amount, address indexed tokenAddress, uint256 stillAccruedAmount);

    /// @notice Emitted when a user claims all available rewards across all reward tokens.
    /// @dev Detailed per-token amounts are emitted separately via {RewardPaid} events.
    event ClaimAll(address indexed userAddress, uint256 tokenTypesClaimed);

    // ───────────────────── Reward Lifecycle ──────────────────────
    /// @notice Emitted when a new reward token is added.
    event RewardTokenAdded(uint256 indexed rewardIndex, address indexed tokenAddress);

    /**
     * @notice Emitted when a reward schedule is funded (or extended/rolled over).
     * @param rewardIndex  Reward token index.
     * @param rewardAmount Newly transferred funding amount (current tx).
     * @param duration     Emission duration for the new schedule.
     * @param fromAddress  Funding wallet (DISTRIBUTOR_ROLE).
     * @param leftover     Remaining rewards from previous active schedule (if any).
     * @param totalFunding rewardAmount + leftover + dust (basis for newRate).
     * @param newRate      Emission rate in tokens/sec computed from totalFunding/duration.
     */
    event RewardFunded(
        uint256 indexed rewardIndex,
        uint256 rewardAmount,
        uint256 duration,
        address fromAddress,
        uint256 leftover,
        uint256 totalFunding,
        uint256 newRate
    );

    // ──────────────── Governance / Safety Valves ─────────────────
    /// @notice Emitted when a non-staking, non-reward ERC20 is rescued by governance.
    event ERC20RescuedFromStaking(address indexed tokenAddress, uint256 amount, address indexed receiverAddress, address byAddress);

    // ──────────────── Pause / Unpause Management ─────────────────
    /// @notice Emitted when global pause is activated.
    event StakingGlobalPaused(address byAddress);

    /// @notice Emitted when global pause is lifted.
    event StakingGlobalUnpaused(address byAddress);

    /// @notice Emitted when deposits are paused.
    event StakingDepositsPaused(address byAddress);

    /// @notice Emitted when deposits are unpaused.
    event StakingDepositsUnpaused(address byAddress);

    /// @notice Emitted when withdrawals are paused.
    event StakingWithdrawalsPaused(address byAddress);

    /// @notice Emitted when withdrawals are unpaused.
    event StakingWithdrawalsUnpaused(address byAddress);

    /*//////////////////////////////////////////////////////////////
                        EVENTS (BirdieswapEventRelayerV1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the EventRelayer implementation is upgraded.
    event EventRelayerUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);

    /*//////////////////////////////////////////////////////////////
                    RELAY EVENTS (BirdieswapStorageV1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the storage implementation is upgraded.
    function emitStorageUpgraded(address _oldImplementation, address _newImplementation, address _upgrader) external onlyBirdieswap {
        emit StorageUpgraded(_oldImplementation, _newImplementation, _upgrader);
    }

    /*//////////////////////////////////////////////////////////////
                    RELAY EVENTS (BirdieswapRouterV1)
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── User Interactions ─────────────────────
    /// @notice Emitted after a swap of underlying-in → underlying-out is completed.
    function emitSwap(
        address _user,
        address _caller,
        address _tokenIn,
        uint24 _feeTier,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOut,
        address _referrerAddress
    ) external onlyBirdieswap {
        emit Swap(_user, _caller, _tokenIn, _feeTier, _tokenOut, _amountIn, _amountOut, _referrerAddress);
    }

    // ──────────────────── Governance / Admin ─────────────────────
    function emitGlobalPaused(address _account) external onlyBirdieswap {
        emit GlobalPaused(_account);
    }

    function emitGlobalUnpaused(address _account) external onlyBirdieswap {
        emit GlobalUnpaused(_account);
    }

    function emitDepositsPaused(address _account) external onlyBirdieswap {
        emit DepositsPaused(_account);
    }

    function emitDepositsUnpaused(address _account) external onlyBirdieswap {
        emit DepositsUnpaused(_account);
    }

    function emitSwapsPaused(address _account) external onlyBirdieswap {
        emit SwapsPaused(_account);
    }

    function emitSwapsUnpaused(address _account) external onlyBirdieswap {
        emit SwapsUnpaused(_account);
    }

    /// @notice Emitted when Underlying ↔ Single vault mapping has been set.
    function emitSingleVaultMappingSet(address _underlyingTokenAddress, address _bTokenAddressOld, address _bTokenAddressNew)
        external
        onlyBirdieswap
    {
        emit SingleVaultMappingSet(_underlyingTokenAddress, _bTokenAddressOld, _bTokenAddressNew);
    }

    /// @notice Emitted when bTokens ordered (bToken0 < bToken1) ↔ Dual vault mapping has been set.
    function emitDualVaultMappingSet(
        address _bToken0Address,
        address _bToken1Address,
        address _blpTokenAddressOld,
        address _blpTokenAddressNew
    ) external onlyBirdieswap {
        emit DualVaultMappingSet(_bToken0Address, _bToken1Address, _blpTokenAddressOld, _blpTokenAddressNew);
    }

    /// @notice Emitted when admin toggles whitelist status of a reward token.
    function emitRewardTokenWhitelistSet(address _tokenAddress, bool _allowed, address _byAddress) external onlyBirdieswap {
        emit RewardTokenWhitelistSet(_tokenAddress, _allowed, _byAddress);
    }

    /// @notice Emitted when a contract address is added/removed from the authorized Birdieswap list.
    function emitBirdieswapContractListSet(address _contractAddress, bool _isTrue, address _byAddress) external onlyBirdieswap {
        emit BirdieswapContractListSet(_contractAddress, _isTrue, _byAddress);
    }

    /// @notice Emitted when the official Event Relayer contract address is updated.
    function emitBirdieswapEventRelayerAddressSet(address _contractAddress, address _byAddress) external onlyBirdieswap {
        emit BirdieswapEventRelayerAddressSet(_contractAddress, _byAddress);
    }

    /// @notice Emitted when the official Role Router contract address is updated.
    function emitBirdieswapRoleRouterAddressSet(address _contractAddress, address _byAddress) external onlyBirdieswap {
        emit BirdieswapRoleRouterAddressSet(_contractAddress, _byAddress);
    }

    /// @notice Emitted when the official Fee Collecting address is updated.
    function emitBirdieswapFeeCollectingAddressSet(address _address, address _byAddress) external onlyBirdieswap {
        emit BirdieswapFeeCollectingAddressSet(_address, _byAddress);
    }

    /// @notice Emitted when the router implementation is upgraded.
    function emitRouterUpgraded(address _oldImplementation, address _newImplementation, address _upgrader) external onlyBirdieswap {
        emit RouterUpgraded(_oldImplementation, _newImplementation, _upgrader);
    }

    /// @notice Emitted when the router's Config address is updated.
    function emitRouterConfigAddressSet(address _address, address _byAddress) external onlyBirdieswap {
        emit RouterConfigAddressSet(_address, _byAddress);
    }

    /*//////////////////////////////////////////////////////////////
                    RELAY EVENTS (BirdieswapWrapperV1)
    //////////////////////////////////////////////////////////////*/

    // ──────────────────── Deposits & Redeems ─────────────────────
    /// @notice Emitted when a user deposits ETH through the wrapper to mint a bToken.
    function emitSingleDepositETH(address _user, uint256 _ethAmount, uint256 _bTokenAmount) external onlyBirdieswap {
        emit SingleDepositETH(_user, _ethAmount, _bTokenAmount);
    }

    /// @notice Emitted when a user redeems bTokens through the wrapper to receive WETH.
    function emitSingleRedeemETH(address _user, address _bToken, uint256 _wethAmount) external onlyBirdieswap {
        emit SingleRedeemETH(_user, _bToken, _wethAmount);
    }

    /// @notice Emitted when a user deposits ETH + ERC20 token through the wrapper to mint a blpToken.
    function emitDualDepositWithETH(address _user, uint256 _ethAmount, address _tokenAddress, uint256 _tokenAmount, uint256 _blpTokenAmount)
        external
        onlyBirdieswap
    {
        emit DualDepositWithETH(_user, _ethAmount, _tokenAddress, _tokenAmount, _blpTokenAmount);
    }

    /// @notice Emitted when a user redeems a blpToken through the wrapper and receives ETH + ERC20 tokens.
    function emitDualRedeemToETH(
        address _user,
        address _blpToken,
        address _token0Address,
        uint256 _token0Amount,
        address _token1Address,
        uint256 _token1Amount
    ) external onlyBirdieswap {
        emit DualRedeemToETH(_user, _blpToken, _token0Address, _token0Amount, _token1Address, _token1Amount);
    }

    // ───────────────────────── Swaps ─────────────────────────────
    /// @notice Emitted when a user swaps ETH for a token through the wrapper.
    function emitSwapFromETH(address _user, uint256 _ethIn, address _tokenOut, uint256 _amountOut) external onlyBirdieswap {
        emit SwapFromETH(_user, _ethIn, _tokenOut, _amountOut);
    }

    /// @notice Emitted when a user swaps a token for ETH through the wrapper.
    function emitSwapToETH(address _user, address _tokenIn, uint256 _tokenInAmount, uint256 _ethOut) external onlyBirdieswap {
        emit SwapToETH(_user, _tokenIn, _tokenInAmount, _ethOut);
    }

    /*//////////////////////////////////////////////////////////////
                RELAY EVENTS (BirdieswapSingleVaultV1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every user deposit (vanilla → Birdieswap bToken).
    function emitSingleDeposit(
        address _receiver,
        address _underlyingTokenAddress,
        uint256 _underlyingTokenAmount,
        address _bTokenAddress,
        uint256 _bTokenAmount
    ) external onlyBirdieswap {
        emit SingleDeposit(_receiver, _underlyingTokenAddress, _underlyingTokenAmount, _bTokenAddress, _bTokenAmount);
    }

    /// @notice Emitted on every user withdrawal (bToken → vanilla).
    function emitSingleWithdraw(
        address _receiver,
        address _bTokenAddress,
        uint256 _bTokenAmount,
        address _underlyingTokenAddress,
        uint256 _underlyingTokenAmount
    ) external onlyBirdieswap {
        emit SingleWithdraw(_receiver, _bTokenAddress, _bTokenAmount, _underlyingTokenAddress, _underlyingTokenAmount);
    }

    // ──────────────── Governance / Safety Valves ─────────────────
    /// @notice Emitted when a new strategy is proposed by governance (TimelockController).
    function emitSingleStrategyProposed(address _proposedStrategy) external onlyBirdieswap {
        emit SingleStrategyProposed(_proposedStrategy);
    }

    /// @notice Emitted when governance updates the strategy contract.
    function emitSingleStrategyAccepted(address _oldStrategy, address _newStrategy) external onlyBirdieswap {
        emit SingleStrategyAccepted(_oldStrategy, _newStrategy);
    }

    /// @notice Emitted when the strategy proposal/accept fails the validation.
    function emitSingleStrategyValidationFailed(address _proposedStrategy, SingleStrategyValidationReason _reason)
        external
        onlyBirdieswap
    {
        emit SingleStrategyValidationFailed(_proposedStrategy, _reason);
    }

    /// @notice Emitted when an emergency exit is executed
    function emitSingleEmergencyExitTriggered(address _strategy, uint256 _exitAmount) external onlyBirdieswap {
        emit SingleEmergencyExitTriggered(_strategy, _exitAmount);
    }

    /// @notice Emitted when a non-staking, non-reward ERC20 is rescued by governance.
    function emitERC20RescuedFromSingleVault(address _tokenAddress, uint256 _amount, address _receiverAddress, address _byAddress)
        external
        onlyBirdieswap
    {
        emit ERC20RescuedFromSingleVault(_tokenAddress, _amount, _receiverAddress, _byAddress);
    }

    /// @notice Emitted when deposits (and swaps) are paused by governance.
    function emitSingleDepositsPaused(address _account) external onlyBirdieswap {
        emit SingleDepositsPaused(_account);
    }

    /// @notice Emitted when deposits (and swaps) are unpaused by governance.
    function emitSingleDepositsUnpaused(address _account) external onlyBirdieswap {
        emit SingleDepositsUnpaused(_account);
    }

    /*//////////////////////////////////////////////////////////////
               RELAY EVENTS (BirdieswapSingleStrategyV1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when compounding or reward reinvestment occurs.
    function emitSingleHardWork(address _claimedTokenAddress, uint256 _claimedTokenAmount, uint256 _autoCompoundedAmount)
        external
        onlyBirdieswap
    {
        emit SingleHardWork(_claimedTokenAddress, _claimedTokenAmount, _autoCompoundedAmount);
    }

    /*//////////////////////////////////////////////////////////////
                RELAY EVENTS (BirdieswapDualVaultV1)
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── User Interactions ─────────────────────
    // Emitted on user-initiated deposit and redemption flows.
    /// @notice Emitted after a successful dual-token deposit.
    function emitDualDeposit(
        address _owner,
        address _bToken0Address,
        uint256 _bToken0Amount,
        address _bToken1Address,
        uint256 _bToken1Amount,
        address _blpTokenAddress,
        uint256 _blpTokenAmount
    ) external onlyBirdieswap {
        emit DualDeposit(_owner, _bToken0Address, _bToken0Amount, _bToken1Address, _bToken1Amount, _blpTokenAddress, _blpTokenAmount);
    }

    /// @notice Emitted after a successful dual-token redemption.
    function emitDualWithdraw(
        address _caller,
        address _blpTokenAddress,
        uint256 _blpTokenAmount,
        address _bToken0Address,
        uint256 _bToken0Amount,
        address _bToken1Address,
        uint256 _bToken1Amount
    ) external onlyBirdieswap {
        emit DualWithdraw(_caller, _blpTokenAddress, _blpTokenAmount, _bToken0Address, _bToken0Amount, _bToken1Address, _bToken1Amount);
    }

    // ──────────────── Token / NFT Custody Events ─────────────────
    // Record of custody events for Uniswap V3 position NFTs held by the vault.
    /// @notice Emitted when the vault receives an ERC721 (e.g., Uniswap position NFT).
    function emitNFTReceived(address _operator, address _from, uint256 _tokenId, bytes calldata _data) external onlyBirdieswap {
        emit NFTReceived(_operator, _from, _tokenId, _data);
    }

    // ─────────────── ERC-4626 Compatibility Events ───────────────
    // Informational hooks for unsupported single-asset entrypoints.
    /// @notice Emitted when a single-asset mint() is attempted on this dual-asset vault.
    function emitMintNotSupported(address _sender, uint256 _shares, address _receiver) external onlyBirdieswap {
        emit MintNotSupported(_sender, _shares, _receiver);
    }

    /// @notice Emitted when a single-asset withdraw() is attempted on this dual-asset vault.
    function emitWithdrawNotSupported(address _sender, uint256 _assets, address _receiver, address _owner) external onlyBirdieswap {
        emit WithdrawNotSupported(_sender, _assets, _receiver, _owner);
    }

    /// @notice Emitted when a single-token deposit() call is attempted instead of a dual-token deposit.
    function emitMustDepositTwoTokens(address _sender, uint256 _assets, address _receiver) external onlyBirdieswap {
        emit MustDepositTwoTokens(_sender, _assets, _receiver);
    }

    /// @notice Emitted when a single-asset redeem() path is attempted instead of a proper dual redemption.
    function emitMustRedeemProperly(address _sender, uint256 _shares, address _receiver, address _owner) external onlyBirdieswap {
        emit MustRedeemProperly(_sender, _shares, _receiver, _owner);
    }

    // ─────────────── Governance / Strategy Lifecycle ─────────────
    // Governance lifecycle: strategy management, emergency exits, and rescues.
    /// @notice Emitted when a valid strategy proposal is staged by governance.
    function emitDualStrategyProposed(address _proposedStrategy) external onlyBirdieswap {
        emit DualStrategyProposed(_proposedStrategy);
    }

    /// @notice Emitted when the new strategy contract has been accepted.
    function emitDualStrategyAccepted(address _oldStrategy, address _newStrategy) external onlyBirdieswap {
        emit DualStrategyAccepted(_oldStrategy, _newStrategy);
    }

    /// @notice Emitted when a proposed or pending strategy fails validation checks.
    function emitDualStrategyValidationFailed(address _proposedStrategy, DualStrategyValidationReason _reason) external onlyBirdieswap {
        emit DualStrategyValidationFailed(_proposedStrategy, _reason);
    }

    // ───────────────── Emergency & Safety Valves ─────────────────
    /// @notice Emitted when governance executes an emergency exit to reclaim all managed assets.
    function emitDualEmergencyExitTriggered(address _strategy, uint256 _exitAmount0, uint256 _exitAmount1) external onlyBirdieswap {
        emit DualEmergencyExitTriggered(_strategy, _exitAmount0, _exitAmount1);
    }

    /// @notice Emitted when a non-core ERC20 is rescued by governance through {rescueERC20()}.
    function emitERC20RescuedFromDualVault(address _tokenAddress, uint256 _amount, address _receiverAddress, address _byAddress)
        external
        onlyBirdieswap
    {
        emit ERC20RescuedFromDualVault(_tokenAddress, _amount, _receiverAddress, _byAddress);
    }

    /*//////////////////////////////////////////////////////////////
                RELAY EVENTS (BirdieswapDualStrategyV1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful `doHardWork()` compounding cycle.
    function emitDualHardWork(uint256 _liquidity, uint256 _bToken0, uint256 _bToken1, uint256 _operationWETHFee) external onlyBirdieswap {
        emit DualHardWork(_liquidity, _bToken0, _bToken1, _operationWETHFee);
    }

    /// @notice Emitted when the strategy performs an emergency exit and returns funds to the DualVault.
    function emitDualEmergencyExit(uint256 _bToken0Amount, uint256 _bToken1Amount) external onlyBirdieswap {
        emit DualEmergencyExit(_bToken0Amount, _bToken1Amount);
    }

    /*//////////////////////////////////////////////////////////////
                    RELAY EVENTS (BirdieswapStakingV1)
    //////////////////////////////////////////////////////////////*/

    // ───────────────────── User Interactions ─────────────────────
    /// @notice Emitted on deposit of staking tokens by a user.
    function emitStakingDeposit(address _userAddress, uint256 _amount, address _tokenAddress) external onlyBirdieswap {
        emit StakingDeposit(_userAddress, _amount, _tokenAddress);
    }

    /// @notice Emitted on withdrawal of staking tokens by a user (rewards may or may not be claimed).
    function emitStakingWithdraw(address _userAddress, uint256 _amount, address _tokenAddress) external onlyBirdieswap {
        emit StakingWithdraw(_userAddress, _amount, _tokenAddress);
    }

    /// @notice Emitted when a user performs an emergency withdraw (all rewards forfeited).
    function emitEmergencyWithdraw(address _userAddress, uint256 _amount, address _tokenAddress) external onlyBirdieswap {
        emit EmergencyWithdraw(_userAddress, _amount, _tokenAddress);
    }

    /// @notice Emitted when rewards are explicitly forfeited (e.g., via emergencyWithdraw).
    function emitRewardsForfeited(address _userAddress, uint256[] calldata _indices, uint256[] calldata _amounts) external onlyBirdieswap {
        emit RewardsForfeited(_userAddress, _indices, _amounts);
    }

    /// @notice Emitted whenever rewards are paid out in full for a specific reward token.
    function emitRewardPaid(address _userAddress, uint256 _amount, address _tokenAddress) external onlyBirdieswap {
        emit RewardPaid(_userAddress, _amount, _tokenAddress);
    }

    /// @notice Emitted when only a partial reward can be paid due to insufficient contract balance.
    function emitRewardPartiallyPaid(address _userAddress, uint256 _amount, address _tokenAddress, uint256 _stillAccruedAmount)
        external
        onlyBirdieswap
    {
        emit RewardPartiallyPaid(_userAddress, _amount, _tokenAddress, _stillAccruedAmount);
    }

    /// @notice Emitted when a user claims all available rewards across all reward tokens.
    function emitClaimAll(address _userAddress, uint256 _tokenTypesClaimed) external onlyBirdieswap {
        emit ClaimAll(_userAddress, _tokenTypesClaimed);
    }

    // ───────────────────── Reward Lifecycle ──────────────────────
    /// @notice Emitted when a new reward token is added.
    function emitRewardTokenAdded(uint256 _rewardIndex, address _tokenAddress) external onlyBirdieswap {
        emit RewardTokenAdded(_rewardIndex, _tokenAddress);
    }

    /// @notice Emitted when a reward schedule is funded (or extended/rolled over).
    function emitRewardFunded(
        uint256 _rewardIndex,
        uint256 _rewardAmount,
        uint256 _duration,
        address _fromAddress,
        uint256 _leftover,
        uint256 _totalFunding,
        uint256 _newRate
    ) external onlyBirdieswap {
        emit RewardFunded(_rewardIndex, _rewardAmount, _duration, _fromAddress, _leftover, _totalFunding, _newRate);
    }

    // ──────────────── Governance / Safety Valves ─────────────────
    /// @notice Emitted when a non-staking, non-reward ERC20 is rescued by governance.
    function emitERC20RescuedFromStaking(address _tokenAddress, uint256 _amount, address _receiverAddress, address _byAddress)
        external
        onlyBirdieswap
    {
        emit ERC20RescuedFromStaking(_tokenAddress, _amount, _receiverAddress, _byAddress);
    }

    // ──────────────── Pause / Unpause Management ─────────────────
    /// @notice Emitted when global pause is activated.
    function emitStakingGlobalPaused(address _byAddress) external onlyBirdieswap {
        emit StakingGlobalPaused(_byAddress);
    }

    /// @notice Emitted when global pause is lifted.
    function emitStakingGlobalUnpaused(address _byAddress) external onlyBirdieswap {
        emit StakingGlobalUnpaused(_byAddress);
    }

    /// @notice Emitted when deposits are paused.
    function emitStakingDepositsPaused(address _byAddress) external onlyBirdieswap {
        emit StakingDepositsPaused(_byAddress);
    }

    /// @notice Emitted when deposits are unpaused.
    function emitStakingDepositsUnpaused(address _byAddress) external onlyBirdieswap {
        emit StakingDepositsUnpaused(_byAddress);
    }

    /// @notice Emitted when withdrawals are paused.
    function emitStakingWithdrawalsPaused(address _byAddress) external onlyBirdieswap {
        emit StakingWithdrawalsPaused(_byAddress);
    }

    /// @notice Emitted when withdrawals are unpaused.
    function emitStakingWithdrawalsUnpaused(address _byAddress) external onlyBirdieswap {
        emit StakingWithdrawalsUnpaused(_byAddress);
    }
}
/*//////////////////////////////////////////////////////////////
                    END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant Only registered modules in BirdieswapStorageV1 can relay events.
/// @custom:invariant All emitted events are globally indexed for off-chain data aggregation.
