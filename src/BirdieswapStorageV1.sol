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
import { IBirdieswapEventRelayerV1 } from "./interfaces/IBirdieswapEventRelayerV1.sol";

/*//////////////////////////////////////////////////////////////
                            CONTRACT
//////////////////////////////////////////////////////////////*/
/**
 * @title  BirdieswapStorageV1
 * @author Birdieswap Team
 * @notice Defines the shared mutable storage for Birdieswap V1.
 */
contract BirdieswapStorageV1 is Initializable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error BirdieswapStorageV1__UnauthorizedAccess();
    error BirdieswapStorageV1__IdenticalTokens();
    error BirdieswapStorageV1__ZeroAddressNotAllowed();

    /*//////////////////////////////////////////////////////////////
                              DATA STRUCTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Represents a dual vault pairing of two bTokens.
    struct DualVault {
        address bToken0Address;
        address bToken1Address;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Contract version identifier.
    string internal constant CONTRACT_VERSION = "BirdieswapStorageV1";

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ────────────────────── Vault mappings ───────────────────────
    mapping(address => address) public underlyingToBToken; // underlying → bToken
    mapping(address => address) public bTokenToUnderlying; // bToken → underlying
    mapping(address => mapping(address => address)) internal bTokenPairToBLPToken; // ordered pair → blpToken
    mapping(address => DualVault) public blpTokenToBTokenPair; // blpToken → pair

    // ────────────────────────── Staking ──────────────────────────
    mapping(address => bool) public rewardTokenWhitelist;

    // ──────────────────── Protocol boundaries ────────────────────
    mapping(address => bool) public isBirdieswap;

    // ────────────────────── Core addresses ───────────────────────
    address public s_timelockControllerAddress;
    address public s_routerAddress;
    address public s_eventRelayerAddress;
    address public s_roleRouterAddress;
    address public s_feeCollectingAddress;

    // ────────────────────── Upgradeable gap ──────────────────────
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyTimelock() {
        if (msg.sender != s_timelockControllerAddress) revert BirdieswapStorageV1__UnauthorizedAccess();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != s_routerAddress) revert BirdieswapStorageV1__UnauthorizedAccess();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize core addresses.
     * @param _timelock             Timelock/governance address (authorized for upgrades & governance changes)
     * @param _router               Router contract (authorized for operational writes)
     * @param _relayer              Event relayer (optional; can be updated later)
     * @param _roleRouter           Role router address
     * @param _feeCollectingAddress Fee collecting address
     */
    function initialize(address _timelock, address _router, address _relayer, address _roleRouter, address _feeCollectingAddress)
        public
        initializer
    {
        __UUPSUpgradeable_init();

        s_timelockControllerAddress = _timelock;
        s_routerAddress = _router;
        s_eventRelayerAddress = _relayer;
        s_roleRouterAddress = _roleRouter;
        s_feeCollectingAddress = _feeCollectingAddress;
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE
    //////////////////////////////////////////////////////////////*/
    /// @dev UUPS authorization: only timelock can upgrade implementation.
    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != s_timelockControllerAddress) revert BirdieswapStorageV1__UnauthorizedAccess();

        // Best-effort governance transparency (don’t brick if relayer unset)
        address eventRelayerAddress = s_eventRelayerAddress;
        try IBirdieswapEventRelayerV1(eventRelayerAddress).emitStorageUpgraded(
            ERC1967Utils.getImplementation(), newImplementation, msg.sender
        ) { } catch { }
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    // ─────────────── Router-only setters ───────────────
    function setUnderlyingToBToken(address _underlyingTokenAddress, address _bTokenAddress) external onlyRouter {
        if (_underlyingTokenAddress == address(0) || _bTokenAddress == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        underlyingToBToken[_underlyingTokenAddress] = _bTokenAddress;
    }

    function setBTokenToUnderlying(address _bTokenAddress, address _underlyingTokenAddress) external onlyRouter {
        if (_bTokenAddress == address(0) || _underlyingTokenAddress == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        bTokenToUnderlying[_bTokenAddress] = _underlyingTokenAddress;
    }

    /// @notice Register or overwrite a dual-vault mapping after normalizing the pair to (min,max).
    /// @dev Intentionally allows overwrites; safety ensured at Router level.
    function setBLPMapping(address _blpTokenAddress, address _bTokenA, address _bTokenB) external onlyRouter {
        if (_blpTokenAddress == address(0) || _bTokenA == address(0) || _bTokenB == address(0)) {
            revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        }
        if (_bTokenA == _bTokenB) revert BirdieswapStorageV1__IdenticalTokens();

        (address b0, address b1) = _bTokenA < _bTokenB ? (_bTokenA, _bTokenB) : (_bTokenB, _bTokenA);

        blpTokenToBTokenPair[_blpTokenAddress] = DualVault({ bToken0Address: b0, bToken1Address: b1 });
        bTokenPairToBLPToken[b0][b1] = _blpTokenAddress;
    }

    function setRewardTokenWhitelist(address _tokenAddress, bool _allowed) external onlyRouter {
        rewardTokenWhitelist[_tokenAddress] = _allowed;
    }

    function setBirdieswapContract(address _contractAddress, bool _isTrue) external onlyRouter {
        isBirdieswap[_contractAddress] = _isTrue;
    }

    function setEventRelayerAddress(address _contractAddress) external onlyRouter {
        if (_contractAddress == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        s_eventRelayerAddress = _contractAddress;
    }

    function setRoleRouterAddress(address _contractAddress) external onlyRouter {
        if (_contractAddress == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        s_roleRouterAddress = _contractAddress;
    }

    function setFeeCollectingAddress(address _collectingAddress) external onlyRouter {
        if (_collectingAddress == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        s_feeCollectingAddress = _collectingAddress;
    }

    function setRouterAddress(address _routerAddress) external onlyRouter {
        if (_routerAddress == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        s_routerAddress = _routerAddress;
    }

    // ─────────────── Timelock-only setters ───────────────
    function setTimelockControllerAddress(address _timelock) external onlyTimelock {
        if (_timelock == address(0)) revert BirdieswapStorageV1__ZeroAddressNotAllowed();
        s_timelockControllerAddress = _timelock;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW GETTERS
    //////////////////////////////////////////////////////////////*/
    /// @notice Return the contract version.
    function getVersion() external pure returns (string memory) {
        return CONTRACT_VERSION;
    }

    /// @notice Lookup dual vault (blpToken) by unordered bToken pair (internally ordered to (min,max)).
    function getBLPTokenAddress(address _bToken0Address, address _bToken1Address) external view returns (address) {
        (address b0, address b1) =
            _bToken0Address < _bToken1Address ? (_bToken0Address, _bToken1Address) : (_bToken1Address, _bToken0Address);
        return bTokenPairToBLPToken[b0][b1];
    }
}
