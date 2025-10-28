// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
import { IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

/**
 * @title  IBirdieswapSingleVaultV1
 * @author Birdieswap Team
 * @notice Canonical interface for the Birdieswap Single Vault V1.
 *
 * @dev Standards:
 * - Inherits ERC4626 surface area (IERC4626) and EIP-2612 permit (IERC20Permit).
 * - Shares are this vault’s bTokens. `asset()` in ERC4626 terms refers to the *strategy’s proof token*,
 *   while `underlyingToken()` below returns the *ultimate vanilla asset* users care about.
 *
 * Bootstrap & gas design (important for integrators):
 * - `getStrategy()` can be zero only during the bootstrap flow (deploy → propose → accept).
 * - To avoid lifetime SLOADs, the vault intentionally does NOT guard hot paths with “strategy set” checks.
 * - Calling deposit/mint/withdraw/redeem/previewFull* before strategy activation will revert via call to
 *   address(0) — **by design**. Integrators MUST gate actions until either:
 *      (a) {StrategyAccepted} is observed, or
 *      (b) `getStrategy() != address(0)`.
 * - Once activated, the strategy address never returns to zero.
 */
interface IBirdieswapSingleVaultV1 is IERC4626 {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BirdieswapSingleVaultV1__ConversionOutOfTolerance();
    error BirdieswapSingleVaultV1__InvalidAmount();
    error BirdieswapSingleVaultV1__NotValidStrategy();
    error BirdieswapSingleVaultV1__ProofTokenAmountDeltaMismatch();
    error BirdieswapSingleVaultV1__StrategyReturnedZero();
    error BirdieswapSingleVaultV1__TimelockMustBeAContract();
    error BirdieswapSingleVaultV1__UnauthorizedAccess();
    error BirdieswapSingleVaultV1__UnderlyingDeltaOutOfTolerance();
    error BirdieswapSingleVaultV1__ZeroAddressNotAllowed();

    error BirdieswapSingleVaultV1__CannotRescueBToken();
    error BirdieswapSingleVaultV1__CannotRescueProofToken();
    error BirdieswapSingleVaultV1__CannotRescueUnderlyingToken();
    error BirdieswapSingleVaultV1__InvalidEmergencyExitReturn();
    error BirdieswapSingleVaultV1__InvalidRoleCombination();

    /*//////////////////////////////////////////////////////////////
                                  ENUMS
    //////////////////////////////////////////////////////////////*/

    enum StrategyValidationReason {
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

    /*//////////////////////////////////////////////////////////////
                              CORE / METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice Human-readable contract version string.
    function version() external pure returns (string memory);

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE / CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Temporarily halts new deposits/mints. Withdrawals/redemptions remain enabled.
     * @dev    Pauser role only.
     */
    function pause() external;

    /// @notice Resumes deposit/mint operations after a pause (Pauser role only).
    function unpause() external;

    /**
     * @notice Proposes a new strategy; activation occurs later via {acceptStrategy()} (timelock-controlled).
     * @dev    Manager role only. Emits {StrategyProposed}. Reverts with {NotValidStrategy} + reason on validation fail.
     */
    function proposeStrategy(address newStrategy) external;

    /**
     * @notice Activates the pending strategy after timelock delay.
     * @dev    Timelock role only. Emits {StrategyAccepted}. Reverts on invalid pending address.
     */
    function acceptStrategy() external;

    /**
     * @notice Emergency: force the strategy to unwind and return underlying to the vault.
     * @dev    Manager role only. Emits {EmergencyExitTriggered}.
     */
    function emergencyExit() external;

    /**
     * @notice Rescue a non-staking, non-reward ERC20 accidentally sent to the vault.
     * @dev    Timelock role only. Forbids rescuing the underlying, proof token, or bToken itself.
     */
    function rescueERC20(address token, address receiver, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current active strategy address (may be zero only during bootstrap).
    function getStrategy() external view returns (address);

    /// @notice Pending strategy awaiting activation via {acceptStrategy()} (zero if none).
    function getPendingStrategy() external view returns (address);

    /**
     * @notice Returns the ultimate redeemable vanilla token for this vault.
     * @dev `asset()` (IERC4626) is the strategy’s proof token; this returns the layer-1 vanilla token.
     */
    function underlyingToken() external view returns (address);

    /// @notice `(absoluteWei, relativeBp)` tolerance parameters used in conversion checks.
    function getTolerances() external pure returns (uint256 absoluteWei, uint256 relativeBp);

    /**
     * @notice Informational helper: total vanilla underlying value represented by the vault
     *         (proof converted to assets + idle underlying in the vault).
     * @dev Not used for accounting; purely informational.
     */
    function totalUnderlyingBalance() external view returns (uint256);

    /// @notice Convenience for integrators: true once a strategy has been activated at least once.
    function isStrategyActive() external view returns (bool);

    /**
     * @notice Health diagnostics comparing previews vs. actual conversions.
     * @param  amount Sample amount to test.
     * @return proofDeviationBp   Deviation (bp) for proof previews vs. actual.
     * @return underlyingDeviationBp Deviation (bp) for underlying previews vs. actual.
     * @return underlyingRatioBp  Ratio (bp) of actual/expected underlying.
     */
    function healthReport(uint256 amount)
        external
        view
        returns (int256 proofDeviationBp, int256 underlyingDeviationBp, uint256 underlyingRatioBp);

    /**
     * @notice Deterministic helper used by invariant tests to compute expected delta bounds.
     * @param  proofAmount  Amount of proof tokens to bound.
     * @param  toleranceBp  Relative tolerance (basis points).
     * @return minAmount    Minimum acceptable value.
     * @return maxAmount    Maximum acceptable value.
     */
    function pureExpectedAssetDelta(uint256 proofAmount, uint256 toleranceBp)
        external
        pure
        returns (uint256 minAmount, uint256 maxAmount);

    /*//////////////////////////////////////////////////////////////
                         BIRDIESWAP PREVIEW EXTENSIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Two-layer preview: underlying → proof (strategy) → bToken (vault shares).
     * @dev    Requires an active strategy; calling during bootstrap will revert by design.
     */
    function previewFullDeposit(uint256 underlyingAmount) external view returns (uint256 bTokenAmount);

    /// @notice Two-layer preview: bToken shares → required underlying.
    function previewFullMint(uint256 bTokenAmount) external view returns (uint256 underlyingAmount);

    /// @notice Two-layer preview: bToken shares → redeemable underlying.
    function previewFullRedeem(uint256 bTokenAmount) external view returns (uint256 underlyingAmount);

    /// @notice Two-layer preview: target underlying → required bToken shares to burn.
    function previewFullWithdraw(uint256 underlyingAmount) external view returns (uint256 bTokenAmount);
}
