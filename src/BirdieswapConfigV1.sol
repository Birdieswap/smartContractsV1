// SPDX-License-Identifier: None
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                        BIRDIESWAP CONFIG V1
    Immutable-only configuration hub for the entire protocol.
    Holds canonical references for WETH, Router, Uniswap infra,
    and governance role identifiers.
//////////////////////////////////////////////////////////////*/

/// @title BirdieswapConfigV1
/// @author Birdieswap
/// @notice Central immutable configuration contract shared by all protocol components.
/// @dev Struct-based constructor avoids stack-too-deep and simplifies deploy scripts.
contract BirdieswapConfigV1 {
    /*//////////////////////////////////////////////////////////////
                                VERSION
    //////////////////////////////////////////////////////////////*/
    string public constant VERSION = "BirdieswapConfigV1";

    /*//////////////////////////////////////////////////////////////
                              CORE ADDRESSES
    //////////////////////////////////////////////////////////////*/
    address public immutable i_weth;
    uint256 public immutable i_processingFee;
    uint24 public immutable i_maxServiceFeeRate;
    address public immutable i_uniswapV3Router;
    address public immutable i_uniswapV3PositionManager;
    address public immutable i_uniswapV3Factory;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_FULL_ROLE = keccak256("GUARDIAN_FULL_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant PRECISION_18 = 1e18;
    uint256 public constant PRECISION_36 = 1e36;
    uint24 public constant BASIS_POINT_BASE = 1e4;

    /*//////////////////////////////////////////////////////////////
                       STRATEGY-RELATED PARAMETERS
    //////////////////////////////////////////////////////////////*/
    uint256 public immutable i_roundingTolerance;
    uint256 public immutable i_liquidityDeadline;
    uint24 public immutable i_maxSlippageRateLiquidity;
    uint24 public immutable i_maxSlippageRateSwap;
    uint128 public immutable i_virtualLiquidity;
    uint32 public immutable i_twapSecondsLiquidity;
    uint32 public immutable i_twapSecondsSwap;

    /*//////////////////////////////////////////////////////////////
                       TOLERANCE (Vault / ERC4626)
    //////////////////////////////////////////////////////////////*/
    uint256 public immutable i_absoluteToleranceInWei;
    uint256 public immutable i_relativeToleranceInBp;

    /*//////////////////////////////////////////////////////////////
                       STAKING / REWARD PARAMETERS
    //////////////////////////////////////////////////////////////*/
    uint256 public immutable i_maxRewardPerFunding;
    uint256 public immutable i_maxRewardTokens;
    uint256 public immutable i_maxRewardSpeed;
    uint256 public immutable i_maxDuration;
    uint256 public immutable i_minDuration;
    uint256 public immutable i_maxTotalSupply;

    /*//////////////////////////////////////////////////////////////
                               STRUCT
    //////////////////////////////////////////////////////////////*/
    struct InitParams {
        // Core infra
        address WETH9;
        address uniswapV3Router;
        address uniswapV3PositionManager;
        address uniswapV3Factory;
        uint256 processingFee;
        // Strategy params
        uint24 maxServiceFeeRate;
        uint256 liquidityDeadline;
        uint24 maxSlippageRateLiquidity;
        uint24 maxSlippageRateSwap;
        uint128 virtualLiquidity;
        uint32 twapSecondsLiquidity;
        uint32 twapSecondsSwap;
        uint256 roundingTolerance;
        // Vault tolerance
        uint256 absoluteToleranceInWei;
        uint256 relativeToleranceInBp;
        // Staking params
        uint256 maxRewardPerFunding;
        uint256 maxRewardTokens;
        uint256 maxRewardSpeed;
        uint256 maxDuration;
        uint256 minDuration;
        uint256 maxTotalSupply;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(InitParams memory p) {
        require(
            p.WETH9 != address(0) && p.uniswapV3Router != address(0) && p.uniswapV3PositionManager != address(0)
                && p.uniswapV3Factory != address(0),
            "ZeroAddress"
        );

        // Core
        i_weth = p.WETH9;
        i_uniswapV3Router = p.uniswapV3Router;
        i_uniswapV3PositionManager = p.uniswapV3PositionManager;
        i_uniswapV3Factory = p.uniswapV3Factory;
        i_processingFee = p.processingFee;
        i_maxServiceFeeRate = p.maxServiceFeeRate;

        // Strategy
        i_liquidityDeadline = p.liquidityDeadline;
        i_maxSlippageRateLiquidity = p.maxSlippageRateLiquidity;
        i_maxSlippageRateSwap = p.maxSlippageRateSwap;
        i_virtualLiquidity = p.virtualLiquidity;
        i_twapSecondsLiquidity = p.twapSecondsLiquidity;
        i_twapSecondsSwap = p.twapSecondsSwap;
        i_roundingTolerance = p.roundingTolerance;

        // Vault tolerance
        i_absoluteToleranceInWei = p.absoluteToleranceInWei;
        i_relativeToleranceInBp = p.relativeToleranceInBp;

        // Staking
        i_maxRewardPerFunding = p.maxRewardPerFunding;
        i_maxRewardTokens = p.maxRewardTokens;
        i_maxRewardSpeed = p.maxRewardSpeed;
        i_maxDuration = p.maxDuration;
        i_minDuration = p.minDuration;
        i_maxTotalSupply = p.maxTotalSupply;
    }

    /*//////////////////////////////////////////////////////////////
                             READ HELPERS
    //////////////////////////////////////////////////////////////*/
    function getCoreComponents() external view returns (address, uint24, uint256) {
        return (i_weth, i_maxServiceFeeRate, i_processingFee);
    }

    function getUniswapComponents() external view returns (address, address, address) {
        return (i_uniswapV3Router, i_uniswapV3PositionManager, i_uniswapV3Factory);
    }
}
/*//////////////////////////////////////////////////////////////
                        END OF CONTRACT
//////////////////////////////////////////////////////////////*/
