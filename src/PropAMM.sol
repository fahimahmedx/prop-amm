// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGlobalStorage {
    function set(bytes32 key, bytes32 value) external;
    function setBatch(bytes32[] calldata keys, bytes32[] calldata values) external;
    function get(address owner, bytes32 key) external view returns (bytes32 value);
}

/**
 * @title PropAMM
 * @notice A Proprietary Automated Market Maker where only the market maker can provide liquidity
 * @dev Integrates with GlobalStorage to prevent frontrunning of price updates
 */
contract PropAMM is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Structures ============

    struct TradingPair {
        IERC20 tokenX;
        IERC20 tokenY;
        uint256 reserveX;
        uint256 reserveY;
        uint256 targetX; // Target amount of X for the curve
        uint8 xRetainDecimals; // Decimals to retain for X price normalization
        uint8 yRetainDecimals; // Decimals to retain for Y price normalization
        bool targetYBasedLock; // Emergency lock flag
        uint256 targetYReference; // Reference value for lock mechanism
        bool exists; // Whether this pair exists
    }

    struct PairParameters {
        uint256 concentration; // Concentration parameter for the curve
        uint256 multX; // Price multiplier for token X
        uint256 multY; // Price multiplier for token Y
    }

    // ============ State Variables ============

    address public marketMaker;
    IGlobalStorage public immutable globalStorage;

    mapping(bytes32 => TradingPair) public pairs;
    bytes32[] public pairIds;

    // ============ Constants for GlobalStorage Keys ============

    // Key prefixes for different parameters in GlobalStorage
    bytes32 private constant CONCENTRATION_PREFIX = keccak256("CONCENTRATION");
    bytes32 private constant MULT_X_PREFIX = keccak256("MULT_X");
    bytes32 private constant MULT_Y_PREFIX = keccak256("MULT_Y");

    // ============ Events ============

    event PairCreated(bytes32 indexed pairId, address indexed tokenX, address indexed tokenY, uint256 concentration);

    event Deposited(bytes32 indexed pairId, uint256 amountX, uint256 amountY);

    event Withdrawn(bytes32 indexed pairId, uint256 amountX, uint256 amountY);

    event Swapped(
        bytes32 indexed pairId,
        address indexed trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event ParametersUpdated(bytes32 indexed pairId, uint256 concentration, uint256 multX, uint256 multY);

    event PairUnlocked(bytes32 indexed pairId);

    // ============ Errors ============

    error OnlyMarketMaker();
    error PairAlreadyExists();
    error PairDoesNotExist();
    error InvalidConcentration();
    error InvalidAmount();
    error InsufficientLiquidity();
    error PairLocked();
    error SlippageExceeded();
    error InvalidDecimalConfiguration();

    // ============ Modifiers ============

    modifier onlyMarketMaker() {
        if (msg.sender != marketMaker) revert OnlyMarketMaker();
        _;
    }

    modifier pairExists(bytes32 pairId) {
        if (!pairs[pairId].exists) revert PairDoesNotExist();
        _;
    }

    // ============ Constructor ============

    constructor(address _marketMaker, address _globalStorage) Ownable(msg.sender) {
        marketMaker = _marketMaker;
        globalStorage = IGlobalStorage(_globalStorage);
    }

    // ============ Market Maker Functions ============

    /**
     * @notice Create a new trading pair
     * @param tokenX Address of token X
     * @param tokenY Address of token Y
     * @param initialConcentration Initial concentration parameter for the curve (1-2000)
     * @param xRetainDecimals Decimals to retain for X
     * @param yRetainDecimals Decimals to retain for Y
     */
    function createPair(
        address tokenX,
        address tokenY,
        uint256 initialConcentration,
        uint8 xRetainDecimals,
        uint8 yRetainDecimals
    ) external onlyMarketMaker returns (bytes32) {
        bytes32 pairId = keccak256(abi.encodePacked(tokenX, tokenY));

        if (pairs[pairId].exists) revert PairAlreadyExists();
        if (initialConcentration < 1 || initialConcentration >= 2000) revert InvalidConcentration();

        // Verify decimal configuration
        uint8 decimalsX = IERC20Metadata(tokenX).decimals();
        uint8 decimalsY = IERC20Metadata(tokenY).decimals();
        if (decimalsX + xRetainDecimals != decimalsY + yRetainDecimals) {
            revert InvalidDecimalConfiguration();
        }

        pairs[pairId] = TradingPair({
            tokenX: IERC20(tokenX),
            tokenY: IERC20(tokenY),
            reserveX: 0,
            reserveY: 0,
            targetX: 0,
            xRetainDecimals: xRetainDecimals,
            yRetainDecimals: yRetainDecimals,
            targetYBasedLock: false,
            targetYReference: 0,
            exists: true
        });

        pairIds.push(pairId);

        // Initialize parameters in GlobalStorage (marketMaker's namespace)
        // Market maker must call this function, so msg.sender = marketMaker
        bytes32[] memory keys = new bytes32[](3);
        bytes32[] memory values = new bytes32[](3);

        keys[0] = _getStorageKey(pairId, CONCENTRATION_PREFIX);
        values[0] = bytes32(initialConcentration);

        keys[1] = _getStorageKey(pairId, MULT_X_PREFIX);
        values[1] = bytes32(0); // multX initialized to 0

        keys[2] = _getStorageKey(pairId, MULT_Y_PREFIX);
        values[2] = bytes32(0); // multY initialized to 0

        globalStorage.setBatch(keys, values);

        emit PairCreated(pairId, tokenX, tokenY, initialConcentration);
        return pairId;
    }

    /**
     * @notice Deposit liquidity into a pair
     */
    function deposit(bytes32 pairId, uint256 amountX, uint256 amountY)
        external
        onlyMarketMaker
        pairExists(pairId)
        nonReentrant
    {
        TradingPair storage pair = pairs[pairId];

        if (amountX > 0) {
            pair.tokenX.safeTransferFrom(msg.sender, address(this), amountX);
            pair.reserveX += amountX;
            pair.targetX += amountX;
        }

        if (amountY > 0) {
            pair.tokenY.safeTransferFrom(msg.sender, address(this), amountY);
            pair.reserveY += amountY;
        }

        emit Deposited(pairId, amountX, amountY);
    }

    /**
     * @notice Withdraw liquidity from a pair
     */
    function withdraw(bytes32 pairId, uint256 amountX, uint256 amountY)
        external
        onlyMarketMaker
        pairExists(pairId)
        nonReentrant
    {
        TradingPair storage pair = pairs[pairId];

        if (amountX > pair.reserveX || amountY > pair.reserveY) {
            revert InsufficientLiquidity();
        }

        if (amountX > 0) {
            pair.reserveX -= amountX;
            pair.targetX -= amountX;
            pair.tokenX.safeTransfer(msg.sender, amountX);
        }

        if (amountY > 0) {
            pair.reserveY -= amountY;
            pair.tokenY.safeTransfer(msg.sender, amountY);
        }

        emit Withdrawn(pairId, amountX, amountY);
    }

    /**
     * @notice Unlock a locked pair
     */
    function unlock(bytes32 pairId) external onlyMarketMaker pairExists(pairId) {
        pairs[pairId].targetYBasedLock = false;
        pairs[pairId].targetYReference = 0;
        emit PairUnlocked(pairId);
    }

    // ============ Public Trading Functions ============

    /**
     * @notice Swap token X for token Y
     * @dev Reads latest parameters from GlobalStorage (top-of-block values)
     * @param pairId The pair identifier
     * @param amountXIn Amount of token X to swap
     * @param minAmountYOut Minimum amount of token Y expected (slippage protection)
     */
    function swapXtoY(bytes32 pairId, uint256 amountXIn, uint256 minAmountYOut)
        external
        pairExists(pairId)
        nonReentrant
        returns (uint256 amountYOut)
    {
        TradingPair storage pair = pairs[pairId];

        // Read latest parameters from GlobalStorage
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);

        // Check if pair is locked
        if (_isTargetYLocked(pairId, params)) revert PairLocked();

        // Get quote using GlobalStorage parameters
        uint256 amountOut = _quoteXtoY(pairId, amountXIn, params);

        if (amountOut < minAmountYOut) revert SlippageExceeded();
        if (amountOut >= pair.reserveY) revert InsufficientLiquidity();

        // Transfer tokens
        pair.tokenX.safeTransferFrom(msg.sender, address(this), amountXIn);
        pair.reserveX += amountXIn;

        pair.reserveY -= amountOut;
        pair.tokenY.safeTransfer(msg.sender, amountOut);

        emit Swapped(pairId, msg.sender, address(pair.tokenX), address(pair.tokenY), amountXIn, amountOut);

        return amountOut;
    }

    /**
     * @notice Swap token Y for token X
     * @dev Reads latest parameters from GlobalStorage (top-of-block values)
     * @param pairId The pair identifier
     * @param amountYIn Amount of token Y to swap
     * @param minAmountXOut Minimum amount of token X expected (slippage protection)
     */
    function swapYtoX(bytes32 pairId, uint256 amountYIn, uint256 minAmountXOut)
        external
        pairExists(pairId)
        nonReentrant
        returns (uint256 amountXOut)
    {
        TradingPair storage pair = pairs[pairId];

        // Read latest parameters from GlobalStorage
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);

        // Check if pair is locked
        if (_isTargetYLocked(pairId, params)) revert PairLocked();

        // Get quote using GlobalStorage parameters
        uint256 amountOut = _quoteYtoX(pairId, amountYIn, params);

        if (amountOut < minAmountXOut) revert SlippageExceeded();
        if (amountOut >= pair.reserveX) revert InsufficientLiquidity();

        // Transfer tokens
        pair.tokenY.safeTransferFrom(msg.sender, address(this), amountYIn);
        pair.reserveY += amountYIn;

        pair.reserveX -= amountOut;
        pair.tokenX.safeTransfer(msg.sender, amountOut);

        emit Swapped(pairId, msg.sender, address(pair.tokenY), address(pair.tokenX), amountYIn, amountOut);

        return amountOut;
    }

    // ============ View Functions ============

    /**
     * @notice Get quote for swapping X to Y using current GlobalStorage parameters
     */
    function quoteXtoY(bytes32 pairId, uint256 amountXIn)
        external
        view
        pairExists(pairId)
        returns (uint256 amountOut)
    {
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);
        return _quoteXtoY(pairId, amountXIn, params);
    }

    /**
     * @notice Get quote for swapping Y to X using current GlobalStorage parameters
     */
    function quoteYtoX(bytes32 pairId, uint256 amountYIn)
        external
        view
        pairExists(pairId)
        returns (uint256 amountOut)
    {
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);
        return _quoteYtoX(pairId, amountYIn, params);
    }

    /**
     * @notice Get current parameters from GlobalStorage
     * @return params The current pricing parameters
     */
    function getParameters(bytes32 pairId) external view returns (PairParameters memory params) {
        return _readParametersFromGlobalStorage(pairId);
    }

    /**
     * @notice Get pair information
     */
    function getPair(bytes32 pairId) external view returns (TradingPair memory) {
        return pairs[pairId];
    }

    /**
     * @notice Get all pair IDs
     */
    function getAllPairIds() external view returns (bytes32[] memory) {
        return pairIds;
    }

    /**
     * @notice Helper to generate pairId from token addresses
     */
    function getPairId(address tokenX, address tokenY) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenX, tokenY));
    }

    /**
     * @notice Get the storage keys for a pair's parameters
     * @dev Market maker uses these keys to call GlobalStorage.setBatch() directly for ToB priority
     * @param pairId The pair identifier
     * @return keys Array of storage keys [concentration, multX, multY]
     */
    function getParameterKeys(bytes32 pairId) external pure returns (bytes32[] memory keys) {
        keys = new bytes32[](3);
        keys[0] = _getStorageKey(pairId, CONCENTRATION_PREFIX);
        keys[1] = _getStorageKey(pairId, MULT_X_PREFIX);
        keys[2] = _getStorageKey(pairId, MULT_Y_PREFIX);
    }

    /**
     * @notice Encode parameters into bytes32 values for GlobalStorage
     * @dev Market maker uses these values to call GlobalStorage.setBatch() directly for ToB priority
     * @param concentration Concentration parameter (1-2000)
     * @param multX Price multiplier for token X
     * @param multY Price multiplier for token Y
     * @return values Array of encoded values [concentration, multX, multY]
     */
    function encodeParameters(uint256 concentration, uint256 multX, uint256 multY)
        external
        pure
        returns (bytes32[] memory values)
    {
        if (concentration < 1 || concentration >= 2000) {
            revert InvalidConcentration();
        }
        values = new bytes32[](3);
        values[0] = bytes32(concentration);
        values[1] = bytes32(multX);
        values[2] = bytes32(multY);
    }

    // ============ Internal Functions ============

    /**
     * @notice Read parameters from GlobalStorage
     * @dev Reads from marketMaker's namespace (set via direct GlobalStorage.setBatch() calls)
     */
    function _readParametersFromGlobalStorage(bytes32 pairId) internal view returns (PairParameters memory params) {
        params.concentration = uint256(globalStorage.get(marketMaker, _getStorageKey(pairId, CONCENTRATION_PREFIX)));

        params.multX = uint256(globalStorage.get(marketMaker, _getStorageKey(pairId, MULT_X_PREFIX)));

        params.multY = uint256(globalStorage.get(marketMaker, _getStorageKey(pairId, MULT_Y_PREFIX)));

        return params;
    }

    /**
     * @notice Generate storage key for a parameter
     */
    function _getStorageKey(bytes32 pairId, bytes32 prefix) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prefix, pairId));
    }

    /**
     * @notice Calculate quote for X to Y swap
     */
    function _quoteXtoY(bytes32 pairId, uint256 amountXIn, PairParameters memory params)
        internal
        view
        returns (uint256 amountOut)
    {
        TradingPair storage pair = pairs[pairId];

        uint256 v0 = pair.targetX * params.concentration;
        uint256 K = (v0 * v0 * params.multX) / params.multY;

        uint256 base = v0 + pair.reserveX - pair.targetX;

        amountOut = K / base - K / (base + amountXIn);
    }

    /**
     * @notice Calculate quote for Y to X swap
     */
    function _quoteYtoX(bytes32 pairId, uint256 amountYIn, PairParameters memory params)
        internal
        view
        returns (uint256 amountOut)
    {
        TradingPair storage pair = pairs[pairId];

        uint256 v0 = pair.targetX * params.concentration;
        uint256 K = (v0 * v0 * params.multX) / params.multY;

        uint256 base = v0 + pair.reserveX - pair.targetX;

        amountOut = base - K / (K / base + amountYIn);
    }

    /**
     * @notice Check if pair should be locked based on target Y deviation
     */
    function _isTargetYLocked(bytes32 pairId, PairParameters memory params) internal returns (bool) {
        TradingPair storage pair = pairs[pairId];

        uint256 targetY = _getTargetY(pairId, params);
        uint256 maxRef = targetY > pair.targetYReference ? targetY : pair.targetYReference;
        pair.targetYReference = maxRef;

        // Lock if deviation exceeds 5%
        if (((pair.targetYReference - targetY) * 10000) / pair.targetYReference > 500) {
            pair.targetYBasedLock = true;
        }

        return pair.targetYBasedLock;
    }

    /**
     * @notice Calculate target Y based on reserves
     */
    function _getTargetY(bytes32 pairId, PairParameters memory params) internal view returns (uint256) {
        TradingPair storage pair = pairs[pairId];

        return
            (pair.reserveX * params.multX + pair.reserveY * params.multY - pair.targetX * params.multX) / params.multY;
    }

    /**
     * @notice Normalize price to target decimals
     */
    function _normalizePrice(uint256 price, uint8 priceDecimals, uint8 targetDecimals)
        internal
        pure
        returns (uint256)
    {
        if (priceDecimals >= targetDecimals) {
            return price / (10 ** (priceDecimals - targetDecimals));
        } else {
            return price * (10 ** (targetDecimals - priceDecimals));
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Update market maker address
     */
    function setMarketMaker(address newMarketMaker) external onlyOwner {
        marketMaker = newMarketMaker;
    }
}

// ============ Interfaces ============

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
