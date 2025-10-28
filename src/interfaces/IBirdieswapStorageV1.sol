// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/**
 * @title  IBirdieswapStorageV1
 * @author Birdieswap Team
 * @notice Interface for BirdieswapStorageV1.
 * @dev    Defines external function signatures and data structures shared across Birdieswap protocol.
 */
interface IBirdieswapStorageV1 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when the router implementation is upgraded.
    event RouterUpgraded(address indexed oldImplementation, address indexed newImplementation, address indexed upgrader);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when an unauthorized caller attempts a restricted operation.
    error BirdieswapStorageV1__UnauthorizedAccess();

    /*//////////////////////////////////////////////////////////////
                              DATA STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Represents a dual vault pairing.
     * @dev Stores the addresses of the two Birdieswap single-vault tokens (bTokens)
     *      that compose a given dual vault.
     */
    struct DualVault {
        address bToken0Address;
        address bToken1Address;
    }

    /*//////////////////////////////////////////////////////////////
                              CORE SETTERS
    //////////////////////////////////////////////////////////////*/

    function setUnderlyingToBToken(address _underlyingTokenAddress, address _bTokenAddress) external;

    function setBTokenToUnderlying(address _bTokenAddress, address _underlyingTokenAddress) external;

    function setBLPMapping(address _blpTokenAddress, address _bTokenA, address _bTokenB) external;

    function setRewardTokenWhitelist(address _tokenAddress, bool _allowed) external;

    function setBirdieswapContract(address _contractAddress, bool _isTrue) external;

    function setEventRelayerAddress(address _contractAddress) external;

    function setFeeCollectingAddress(address _collectingAddress) external;

    function setRouterAddress(address _contractAddress) external;

    function setTimelockControllerAddress(address _contractAddress) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lookup dual vault (blpToken) by unordered bToken pair (internally ordered to (min,max)).
    function getBLPTokenAddress(address _b0, address _b1) external view returns (address);

    /// @notice Retrieve stored bToken addresses behind a dual vault (blpToken).
    function blpTokenToBTokenPair(address _blpTokenAddress) external view returns (DualVault memory);

    /// @notice Returns the bToken associated with a given underlying token.
    function underlyingToBToken(address _underlyingTokenAddress) external view returns (address);

    /// @notice Returns the underlying token associated with a given bToken.
    function bTokenToUnderlying(address _bTokenAddress) external view returns (address);

    /// @notice Check if a given address is a whitelisted reward token.
    function rewardTokenWhitelist(address _tokenAddress) external view returns (bool);

    /// @notice Check if a given address is an official Birdieswap contract.
    function isBirdieswap(address _contractAddress) external view returns (bool);

    /// @notice Returns current router address.
    function s_router() external view returns (address);

    /// @notice Returns current role router address.
    function s_roleRouterAddress() external view returns (address);

    /// @notice Returns fee processor address.
    function s_feeProcessor() external view returns (address);

    /// @notice Returns timelock controller address.
    function s_timelockController() external view returns (address);
}
