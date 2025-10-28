// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title  IBirdieswapSingleStrategyV1
 * @author Birdieswap
 * @notice Interface for the Birdieswap Single Strategy V1.
 * @dev    Minimal adapter surface between the Birdieswap Single Vault (bToken) and an external ERC-4626 pool.
 *         - Mutating functions are intended to be called only by the owning Vault.
 *         - View helpers expose strategy state useful to the Vault and monitoring tools.
 *         - ERC-4626 passthroughs mirror the target pool for accurate previews and limits.
 */
interface IBirdieswapSingleStrategyV1 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when maintenance/compounding is executed.
     * @param claimedTokenAddress Address of the token that was claimed/compounded (the underlying).
     * @param claimedTokenAmount  Amount of underlying processed during the operation.
     * @param autoCompoundedAmount Amount of proof tokens minted and sent back to the Vault.
     */
    event HardWork(address indexed claimedTokenAddress, uint256 claimedTokenAmount, uint256 autoCompoundedAmount);

    /*//////////////////////////////////////////////////////////////
                               CORE FLOWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit underlying tokens held by the strategy into the external ERC-4626 target.
     * @param  _underlyingTokenAmount Amount of underlying to deposit.
     * @return actualProofTokenAmount  Number of proof tokens received from the target pool.
     */
    function deposit(uint256 _underlyingTokenAmount) external returns (uint256 actualProofTokenAmount);

    /**
     * @notice Mint an exact amount of proof tokens from the external ERC-4626 target.
     * @param  _proofTokenAmount          Target number of proof tokens to mint.
     * @return actualUnderlyingTokenAmount Underlying consumed by the mint.
     */
    function mint(uint256 _proofTokenAmount) external returns (uint256 actualUnderlyingTokenAmount);

    /**
     * @notice Redeem proof tokens for underlying from the external ERC-4626 target.
     * @param  _proofTokenAmount          Amount of proof tokens to redeem.
     * @return actualUnderlyingTokenAmount Underlying returned by the redemption.
     */
    function redeem(uint256 _proofTokenAmount) external returns (uint256 actualUnderlyingTokenAmount);

    /**
     * @notice Withdraw an exact amount of underlying from the external ERC-4626 target.
     * @param  _underlyingTokenAmount Amount of underlying to withdraw.
     * @return actualProofTokenAmount  Proof tokens burned to satisfy the withdrawal.
     */
    function withdraw(uint256 _underlyingTokenAmount) external returns (uint256 actualProofTokenAmount);

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the external ERC-4626 investment target (proof token).
    function getTargetVault() external view returns (address);

    /// @notice Address of the Birdieswap Single Vault (the sole authorized caller).
    function getVault() external view returns (address);

    /// @notice Local proof-token balance held by the strategy (normally near zero).
    function getProofTokenAmount() external view returns (uint256);

    /**
     * @notice Estimated total underlying corresponding to the Vault’s current proof-token balance.
     * @dev    Uses the target pool’s preview logic (not a state-changing redemption).
     */
    function getInvestedUnderlyingTokenAmount() external view returns (uint256);

    /**
     * @notice Current investment ratio (invested / (invested + idle)), in basis points.
     * @dev    1e4 = 100%.
     * @return Investment ratio scaled by 1e4.
     */
    function getCurrentInvestmentRate() external view returns (uint24);

    /*//////////////////////////////////////////////////////////////
                         EMERGENCY & MAINTENANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fully unwind the strategy into underlying and return it to the Vault.
     * @dev    Emergency-only operation.
     * @return Amount of underlying transferred back to the Vault.
     */
    function emergencyExit() external returns (uint256);

    /**
     * @notice Redeploy any idle underlying into the external target (e.g., post-emergency or to compound).
     * @return Number of proof tokens minted and transferred to the Vault.
     */
    function doHardWork() external returns (uint256);

    /*//////////////////////////////////////////////////////////////
               ERC-4626 PASSTHROUGH (TARGET POOL VIEW SURFACE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying ERC-20 asset of the external ERC-4626 target.
    function asset() external view returns (address);

    function convertToAssets(uint256 _shares) external view returns (uint256);
    function convertToShares(uint256 _assets) external view returns (uint256);

    function maxDeposit(address _receiver) external view returns (uint256);
    function maxMint(address _receiver) external view returns (uint256);
    function maxRedeem(address _owner) external view returns (uint256);
    function maxWithdraw(address _owner) external view returns (uint256);

    function previewDeposit(uint256 _assets) external view returns (uint256);
    function previewMint(uint256 _shares) external view returns (uint256);
    function previewRedeem(uint256 _shares) external view returns (uint256);
    function previewWithdraw(uint256 _assets) external view returns (uint256);

    /// @notice Total underlying assets reported by the external ERC-4626 target.
    function totalAssets() external view returns (uint256);
}
