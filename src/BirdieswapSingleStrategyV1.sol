// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
// OpenZeppelin imports (openzeppelin-contracts v5.4.0)
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// Birdieswap V1 modules
import { BirdieswapConfigV1 } from "./BirdieswapConfigV1.sol";
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";
import { IBirdieswapSingleVaultV1 } from "./interfaces/IBirdieswapSingleVaultV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapSingleStrategyV1
 * @author Birdieswap
 * @notice Dedicated strategy module that bridges a Birdieswap Single Vault (bToken)
 *         to an external ERC-4626–compatible yield source.
 *
 * @dev    - Operates on a strict 1:1 pairing between one underlying ERC-20 token
 *           and its corresponding ERC-4626 proof token.
 *         - Only the owning Single Vault may invoke state-changing functions.
 *         - All user funds remain under the Vault’s custody; this strategy
 *           temporarily holds assets only during deposit, withdrawal, or
 *           rebalancing operations.
 *         - Implements lightweight passthroughs for ERC-4626 view functions to
 *           preserve interoperability and off-chain integration consistency.
 *         - Emits standardized events via BirdieswapEventRelayerV1 for unified
 *           cross-module analytics and monitoring.
 */
contract BirdieswapSingleStrategyV1 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── Access Control ───────────────────────
    error BirdieswapSingleStrategyV1__OnlyVaultCanCall();

    // ───────────────────── Generic / Validation ───────────────────
    error BirdieswapSingleStrategyV1__ZeroAddressNotAllowed();
    error BirdieswapSingleStrategyV1__NotValidAmount();
    error BirdieswapSingleStrategyV1__InsufficientBalance();

    // ───────────────────── Consistency Checks ─────────────────────
    error BirdieswapSingleStrategyV1__ProofTokenAmountDeltaMismatch();
    error BirdieswapSingleStrategyV1__UnderlyingTokenEstimationMismatch();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version identifier.
    string private constant CONTRACT_VERSION = "BirdieswapSingleStrategyV1";

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // ─────────────────────── External Contracts ───────────────────
    IBirdieswapEventRelayerV1 private immutable i_event;

    // ────────────────────────── Tokens ────────────────────────────
    /// @notice Address of the underlying ERC20 token (e.g., USDC, WETH).
    address private immutable i_underlyingTokenAddress;
    /// @notice Address of the external ERC-4626 vault (investment target).
    address private immutable i_proofTokenAddress;
    /// @notice Address of the Birdieswap Single Vault (bToken contract).
    address private immutable i_bTokenAddress;

    // ──────────────────────── Configuration ───────────────────────
    /// @dev Allowed rounding tolerance (±1 wei) between previewed and actual conversions.
    uint256 private immutable i_roundingTolerance;
    /// @dev Scaling base for percentage-based rate calculations (10000 = 100%).
    uint24 private immutable i_basisPointBase;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes immutable references for config, vault, tokens, and parameters.
     * @param configAddress_        Address of the BirdieswapConfigV1 contract.
     * @param bTokenAddress_        Address of the Birdieswap Single Vault (bToken) linked to this strategy.
     * @param eventRelayerAddress_  Address of the BirdieswapEventRelayerV1 contract.
     */
    constructor(address configAddress_, address bTokenAddress_, address eventRelayerAddress_) {
        // ──────────────────── Validate inputs ────────────────────
        if (configAddress_ == address(0)) revert BirdieswapSingleStrategyV1__ZeroAddressNotAllowed();
        if (bTokenAddress_ == address(0)) revert BirdieswapSingleStrategyV1__ZeroAddressNotAllowed();
        if (eventRelayerAddress_ == address(0)) revert BirdieswapSingleStrategyV1__ZeroAddressNotAllowed();

        // ──────────────────── External contracts ─────────────────
        BirdieswapConfigV1 config = BirdieswapConfigV1(configAddress_);
        i_event = IBirdieswapEventRelayerV1(eventRelayerAddress_);

        // ─────────────────────── Vault setup ─────────────────────
        IBirdieswapSingleVaultV1 bToken = IBirdieswapSingleVaultV1(bTokenAddress_);
        i_underlyingTokenAddress = bToken.underlyingToken();
        i_proofTokenAddress = bToken.asset();
        i_bTokenAddress = bTokenAddress_;

        // ───────────────────── Config values ─────────────────────
        i_roundingTolerance = config.i_roundingTolerance();
        i_basisPointBase = config.BASIS_POINT_BASE();
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts access to calls initiated only by the assigned Single Vault.
    modifier onlyVault() {
        if (msg.sender != i_bTokenAddress) revert BirdieswapSingleStrategyV1__OnlyVaultCanCall();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // ───────────────────────── Metadata ──────────────────────────
    /// @notice Returns the contract version identifier.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    // ───────────────────────── Addresses ─────────────────────────
    /// @notice Returns the ERC-4626 vault (proof token) used as the investment target.
    function getTargetVault() external view returns (address) {
        return i_proofTokenAddress;
    }

    /// @notice Returns the Birdieswap Single Vault (bToken) that owns this strategy.
    function getVault() external view returns (address) {
        return i_bTokenAddress;
    }

    // ───────────────────────── Balances ──────────────────────────
    /// @notice Returns the current balance of proof tokens held by this strategy (expected near zero).
    function getProofTokenAmount() external view returns (uint256) {
        return IERC20(i_proofTokenAddress).balanceOf(address(this));
    }

    /// @notice Returns the total underlying token amount currently invested through this strategy.
    function getInvestedUnderlyingTokenAmount() external view returns (uint256) {
        return _getInvestedUnderlyingTokenAmount();
    }

    // ────────────────────────── Ratios ───────────────────────────
    /**
     * @notice Calculates the current investment ratio of this strategy.
     * @dev    Formula: (invested / (invested + idle)) × i_basisPointBase (1e4 = 100%).
     * @return Current investment rate expressed in basis points.
     */
    function getCurrentInvestmentRate() external view returns (uint24) {
        uint256 idle = IERC20(i_underlyingTokenAddress).balanceOf(address(this));
        uint256 invested = _getInvestedUnderlyingTokenAmount();

        if (invested + idle == 0) return 0;

        return uint24((invested * i_basisPointBase) / (invested + idle));
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL ENTRYPOINTS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────────── Deposit ──────────────────────────
    /**
     * @notice Deposits underlying tokens from the Vault into the external ERC-4626 target.
     * @dev    Mints proof tokens (shares) and immediately transfers them back to the Vault.
     *         Reverts if the strategy’s local balance is insufficient or zero.
     * @param  _underlyingTokenAmount  Amount of underlying asset to deposit.
     * @return actualProofTokenAmount   Proof tokens received from the external vault.
     */
    function deposit(uint256 _underlyingTokenAmount) external onlyVault nonReentrant returns (uint256) {
        _validateTokenAmount(i_underlyingTokenAddress, _underlyingTokenAmount);

        IERC20(i_underlyingTokenAddress).forceApprove(i_proofTokenAddress, _underlyingTokenAmount);
        uint256 actualProofTokenAmount = IERC4626(i_proofTokenAddress).deposit(_underlyingTokenAmount, address(this));
        if (actualProofTokenAmount == 0) revert BirdieswapSingleStrategyV1__ProofTokenAmountDeltaMismatch();

        _sendTokenToVault(i_proofTokenAddress, actualProofTokenAmount);
        return actualProofTokenAmount;
    }

    // ─────────────────────────── Mint ────────────────────────────
    /**
     * @notice Mints an exact amount of proof tokens in exchange for underlying supplied by the Vault.
     * @dev    Reverts if the actual underlying spent differs from the preview by more than ±tolerance.
     * @param  _proofTokenAmount              Target number of proof tokens to mint.
     * @return actualUnderlyingTokenAmount    Underlying tokens consumed to mint the target shares.
     */
    function mint(uint256 _proofTokenAmount) external onlyVault nonReentrant returns (uint256) {
        IERC4626 proofToken = _proofToken();
        uint256 estimatedUnderlyingTokenAmount = proofToken.previewMint(_proofTokenAmount);

        _validateTokenAmount(i_underlyingTokenAddress, estimatedUnderlyingTokenAmount);

        IERC20(i_underlyingTokenAddress).forceApprove(i_proofTokenAddress, estimatedUnderlyingTokenAmount);
        uint256 actualUnderlyingTokenAmount = proofToken.mint(_proofTokenAmount, address(this));

        if (!_isWithinTolerance(estimatedUnderlyingTokenAmount, actualUnderlyingTokenAmount, i_roundingTolerance)) {
            revert BirdieswapSingleStrategyV1__UnderlyingTokenEstimationMismatch();
        }

        _sendTokenToVault(i_proofTokenAddress, _proofTokenAmount);
        return actualUnderlyingTokenAmount;
    }

    // ────────────────────────── Redeem ───────────────────────────
    /**
     * @notice Redeems proof tokens held by the Vault for underlying assets from the external ERC-4626 target.
     * @param  _proofTokenAmount              Amount of proof tokens to redeem.
     * @return actualUnderlyingTokenAmount    Underlying tokens received from redemption.
     */
    function redeem(uint256 _proofTokenAmount) external onlyVault nonReentrant returns (uint256) {
        _validateTokenAmount(i_proofTokenAddress, _proofTokenAmount);

        IERC4626 proofToken = _proofToken();
        uint256 actualUnderlyingTokenAmount = proofToken.redeem(_proofTokenAmount, address(this), address(this));
        if (actualUnderlyingTokenAmount == 0) revert BirdieswapSingleStrategyV1__UnderlyingTokenEstimationMismatch();

        _sendTokenToVault(i_underlyingTokenAddress, actualUnderlyingTokenAmount);
        return actualUnderlyingTokenAmount;
    }

    // ───────────────────────── Withdraw ──────────────────────────
    /**
     * @notice Withdraws a specific amount of underlying from the external ERC-4626 target.
     * @dev    Returns the number of proof tokens burned to complete the withdrawal.
     *         Minor proof-token “dust” may remain due to ERC-4626 rounding.
     * @param  _underlyingTokenAmount  Underlying amount to withdraw.
     * @return actualProofTokenAmount  Proof tokens burned to withdraw the requested assets.
     */
    function withdraw(uint256 _underlyingTokenAmount) external onlyVault nonReentrant returns (uint256) {
        IERC4626 proofToken = _proofToken();
        uint256 estimatedProofTokenAmount = proofToken.previewWithdraw(_underlyingTokenAmount);

        _validateTokenAmount(i_proofTokenAddress, estimatedProofTokenAmount);

        uint256 actualProofTokenAmount = proofToken.withdraw(_underlyingTokenAmount, address(this), address(this));

        if (!_isWithinTolerance(estimatedProofTokenAmount, actualProofTokenAmount, i_roundingTolerance)) {
            revert BirdieswapSingleStrategyV1__ProofTokenAmountDeltaMismatch();
        }

        // Sweep any leftover proof shares (rounding dust) back to the vault
        uint256 dust = IERC20(i_proofTokenAddress).balanceOf(address(this));
        if (dust != 0) _sendTokenToVault(i_proofTokenAddress, dust);

        _sendTokenToVault(i_underlyingTokenAddress, _underlyingTokenAmount);
        return actualProofTokenAmount;
    }

    // ──────────────────────── Maintenance ────────────────────────
    /**
     * @notice Vault-only maintenance function to redeposit any idle underlying balance into the external target.
     * @dev    Typically invoked after an emergency exit or to auto-compound external rewards.
     * @return proofMinted  Amount of proof tokens minted and transferred to the Vault.
     */
    function doHardWork() external onlyVault nonReentrant returns (uint256) {
        IERC20 underlyingToken = IERC20(i_underlyingTokenAddress);
        uint256 underlyingTokenAmount = underlyingToken.balanceOf(address(this));
        if (underlyingTokenAmount == 0) return 0; // Early return if there's nothing to pass back to vault.

        underlyingToken.forceApprove(i_proofTokenAddress, underlyingTokenAmount);
        uint256 proofTokenAmount = IERC4626(i_proofTokenAddress).deposit(underlyingTokenAmount, address(this));

        _sendTokenToVault(i_proofTokenAddress, proofTokenAmount);

        try i_event.emitSingleHardWork(i_underlyingTokenAddress, underlyingTokenAmount, proofTokenAmount) { } catch { }
        return proofTokenAmount;
    }

    // ───────────────────────── Emergency ─────────────────────────
    /**
     * @notice Redeems all proof tokens held by this strategy and transfers the resulting underlying back to the Vault.
     * @dev    Emergency-only function; callable solely by the Vault to fully unwind this strategy’s position.
     * @return underlyingTransferred  Total underlying tokens sent to the Vault.
     */
    function emergencyExit() external onlyVault nonReentrant returns (uint256) {
        IERC4626 proofToken = IERC4626(i_proofTokenAddress);
        proofToken.redeem(proofToken.balanceOf(address(this)), address(this), address(this));

        uint256 underlyingTransferred = IERC20(i_underlyingTokenAddress).balanceOf(address(this));

        _sendTokenToVault(i_underlyingTokenAddress, underlyingTransferred);
        return underlyingTransferred;
    }
    /*//////////////////////////////////////////////////////////////
                ERC-4626-COMPATIBLE VIEW FUNCTIONS (PASSTHROUGH)
    //////////////////////////////////////////////////////////////*/

    // ──────────────────────── Asset Info ─────────────────────────
    /// @notice Returns the underlying asset of the external ERC-4626 target.
    function asset() external view returns (address) {
        return IERC4626(i_proofTokenAddress).asset();
    }

    /// @notice Returns the total underlying assets managed by the external ERC-4626 vault.
    function totalAssets() external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).totalAssets();
    }

    // ──────────────────── Conversion Helpers ─────────────────────
    function convertToAssets(uint256 _shares) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).convertToAssets(_shares);
    }

    function convertToShares(uint256 _assets) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).convertToShares(_assets);
    }

    // ────────────────────── Preview Helpers ──────────────────────
    function previewDeposit(uint256 _assets) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).previewDeposit(_assets);
    }

    function previewMint(uint256 _shares) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).previewMint(_shares);
    }

    function previewWithdraw(uint256 _assets) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).previewWithdraw(_assets);
    }

    function previewRedeem(uint256 _shares) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).previewRedeem(_shares);
    }

    // ─────────────────── Deposit / Mint Limits ───────────────────
    function maxDeposit(address _receiver) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).maxDeposit(_receiver);
    }

    function maxMint(address _receiver) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).maxMint(_receiver);
    }

    function maxWithdraw(address _owner) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).maxWithdraw(_owner);
    }

    // ───────────────── Redeem / Withdraw Limits ──────────────────
    function maxRedeem(address _owner) external view returns (uint256) {
        return IERC4626(i_proofTokenAddress).maxRedeem(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Math Utilities ───────────────────────
    /// @dev Returns true if `a` and `b` differ by no more than `tolerance` wei.
    function _isWithinTolerance(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        return a > b ? a - b <= tolerance : b - a <= tolerance;
    }

    // ───────────────────── Investment Logic ──────────────────────
    /// @dev Computes the total underlying value represented by Vault-held proof tokens.
    function _getInvestedUnderlyingTokenAmount() internal view returns (uint256) {
        IERC4626 proofToken = _proofToken();
        uint256 proofTokenAmount = proofToken.balanceOf(i_bTokenAddress);
        return proofToken.previewRedeem(proofTokenAmount);
    }

    // ───────────────────── Validation Logic ──────────────────────
    /// @dev Ensures `_tokenAmount` is non-zero and that this strategy’s balance
    ///      of `_tokenAddress` is sufficient to cover it.
    function _validateTokenAmount(address _tokenAddress, uint256 _tokenAmount) internal view {
        if (_tokenAmount == 0) revert BirdieswapSingleStrategyV1__NotValidAmount();

        uint256 actualBalance = IERC20(_tokenAddress).balanceOf(address(this));
        if (_tokenAmount > actualBalance) revert BirdieswapSingleStrategyV1__InsufficientBalance();
    }

    // ───────────────────────── Transfers ─────────────────────────
    /// @dev Sends `_tokenAmount` of `_tokenAddress` from this strategy back to the Vault.
    function _sendTokenToVault(address _tokenAddress, uint256 _tokenAmount) internal {
        IERC20(_tokenAddress).safeTransfer(i_bTokenAddress, _tokenAmount);
    }

    // ───────────────────────── Accessors ─────────────────────────
    /// @dev Returns the ERC-4626 proof-token instance used as the external investment target.
    function _proofToken() private view returns (IERC4626) {
        return IERC4626(i_proofTokenAddress);
    }
}
/*//////////////////////////////////////////////////////////////
                          END OF CONTRACT
//////////////////////////////////////////////////////////////*/
/// @custom:invariant Only the assigned Single Vault (i_bTokenAddress) may invoke state-changing functions.
/// — External entrypoints {deposit, mint, redeem, withdraw, doHardWork, emergencyExit} require msg.sender == i_bTokenAddress.
/// @custom:invariant Strategy must not retain user funds beyond transient operations.
/// After each execution: balances of both i_underlyingTokenAddress and i_proofTokenAddress on this contract ≤ i_roundingTolerance.
/// @custom:invariant Strategy permanently bound 1:1 to a specific underlying/proof-token pair.
/// i_underlyingTokenAddress == Vault.underlyingToken() and i_proofTokenAddress == Vault.asset() remain immutable.
/// @custom:invariant ERC-4626 conversion results must stay within configured rounding tolerance.
/// |previewValue − actualValue| ≤ i_roundingTolerance for mint() and withdraw() flows.
/// @custom:invariant Total liquidity (idle + invested) remains conserved except for external ERC-4626 yield/loss.
/// The strategy is value-neutral and does not create or absorb funds beyond the external vault’s behavior.
