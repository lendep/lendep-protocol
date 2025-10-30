// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./CErc20.sol";
import "./EIP20Interface.sol";
import "./interfaces/IUniswapV2Pair.sol";

/**
 * @title Uniswap V2 TWAP Price Oracle
 * @notice Price oracle that uses Uniswap V2 pairs with Time-Weighted Average Price (TWAP)
 * @dev Observes 48 records (one every 30 minutes, covering 24 hours)
 */
contract UniswapV2TwapPriceOracle is PriceOracle {
    /// @notice Number of observations to store (48 records = 24 hours at 30 min intervals)
    uint8 public constant OBSERVATION_COUNT = 48;

    /// @notice Default update interval (30 minutes = 1800 seconds)
    uint32 public constant DEFAULT_UPDATE_INTERVAL = 1800;

    /// @notice Canonical native token placeholder address
    address private constant NATIVE_PLACEHOLDER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Address of the admin
    address public admin;

    /// @notice Update interval in seconds (default 1800 = 30 minutes)
    uint32 public updateInterval;

    /// @notice TWAP window in seconds (default 86400 = 24 hours)
    uint32 public twapWindow;

    /// @notice Mapping from token address to Uniswap V2 Pair address
    mapping(address => address) public tokenPairs;

    /// @notice Wrapped token address for native token
    address public wrappedToken;

    /// @notice Mapping to mark stablecoins (fixed at 1 USDT = 1e18)
    mapping(address => bool) public isStablecoin;

    /// @notice Price observation record
    struct Observation {
        uint32 timestamp; // Block timestamp when observation was recorded
        uint256 price; // Price at this timestamp (scaled by 1e18)
    }

    /// @notice Storage for observations per token
    struct TokenObservations {
        Observation[OBSERVATION_COUNT] observations; // Circular buffer
        uint8 index; // Current index in circular buffer
        uint8 count; // Number of valid observations
    }

    /// @notice Mapping from token address to observations
    mapping(address => TokenObservations) public tokenObservations;

    /// @notice Last update timestamp per token
    mapping(address => uint32) public lastUpdateTime;

    /// @notice Event emitted when pair is set for a token
    event PairSet(address indexed token, address indexed pair);

    /// @notice Event emitted when wrapped token is set
    event WrappedTokenSet(address indexed wrappedToken);

    /// @notice Event emitted when stablecoin is enabled
    event StablecoinEnabled(address indexed token);

    /// @notice Event emitted when stablecoin is disabled
    event StablecoinDisabled(address indexed token);

    /// @notice Event emitted when update interval is changed
    event UpdateIntervalSet(uint32 oldInterval, uint32 newInterval);

    /// @notice Event emitted when price is updated
    event PriceUpdated(address indexed token, uint256 price, uint32 timestamp);

    /**
     * @notice Constructor
     * @param _admin Admin address
     */
    constructor(address _admin) {
        require(_admin != address(0), "Invalid admin address");
        admin = _admin;
        updateInterval = DEFAULT_UPDATE_INTERVAL;
        twapWindow = 86400; // default 24h
    }

    /// @notice Modifier to check if caller is admin
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    /**
     * @notice Get the underlying address of a cToken
     */
    function _getUnderlyingAddress(CToken cToken) private view returns (address) {
        address underlying;

        // Try to call underlying(), if it fails, it's a native token wrapper
        try CErc20(address(cToken)).underlying() returns (address u) {
            underlying = u;
        } catch {
            return NATIVE_PLACEHOLDER;
        }

        // If underlying is wrappedToken, return placeholder (native token)
        if (underlying == wrappedToken) {
            return NATIVE_PLACEHOLDER;
        }

        return underlying;
    }

    /**
     * @notice Get the underlying price from Uniswap V2 pair using TWAP
     * @return The underlying asset price mantissa (scaled by 1e18), 0 if unavailable
     */
    function getUnderlyingPrice(CToken cToken) external override view returns (uint) {
        address token = _getUnderlyingAddress(cToken);
        address queryToken = token;

        // Native token -> wrapped version
        if (token == NATIVE_PLACEHOLDER) {
            queryToken = wrappedToken;
            if (queryToken == address(0)) return 0;
        }

        // Check if token is stablecoin (fixed at 1 USDT = 1e18)
        if (isStablecoin[queryToken]) {
            return 1e18;
        }

        address pair = tokenPairs[queryToken];
        if (pair == address(0)) return 0;

        TokenObservations storage obs = tokenObservations[queryToken];
        if (obs.count < 2) return 0;

        uint32 currentTime = uint32(block.timestamp);
        uint32 windowStart = currentTime >= twapWindow ? currentTime - twapWindow : 0;

        uint256 totalWeightedPrice = 0;
        uint256 totalWeight = 0;
        Observation memory prev;

        // Iterate observations chronologically
        for (uint8 i = 0; i < obs.count; i++) {
            uint8 idx = (obs.count == OBSERVATION_COUNT)
                ? (obs.index + 1 + i) % OBSERVATION_COUNT
                : i;
            Observation memory ob = obs.observations[idx];
            if (ob.timestamp >= windowStart && ob.timestamp <= currentTime) {
                if (prev.timestamp > 0) {
                    uint32 dt = ob.timestamp - prev.timestamp;
                    totalWeightedPrice += prev.price * dt;
                    totalWeight += dt;
                }
                prev = ob;
            }
        }

        // Include last → now
        if (prev.timestamp > 0 && currentTime > prev.timestamp) {
            uint32 dt = currentTime - prev.timestamp;
            totalWeightedPrice += prev.price * dt;
            totalWeight += dt;
        }

        if (totalWeight == 0 || totalWeight < twapWindow / 2) return 0;
        return totalWeightedPrice / totalWeight;
    }

    /**
     * @notice Update price observation for a token
     */
    function update(address token) external {
        address queryToken = token;
        if (token == NATIVE_PLACEHOLDER) {
            queryToken = wrappedToken;
            require(queryToken != address(0), "Wrapped token not set");
        }

        address pair = tokenPairs[queryToken];
        require(pair != address(0), "Pair not set");

        uint32 lastUpdate = lastUpdateTime[queryToken];
        if (lastUpdate > 0 && block.timestamp < lastUpdate + updateInterval) {
            revert("Update interval not reached");
        }

        uint256 price = _getCurrentPrice(pair, queryToken);
        require(price > 0, "Invalid price");

        TokenObservations storage obs = tokenObservations[queryToken];

        uint8 newIndex;
        if (obs.count < OBSERVATION_COUNT) {
            newIndex = obs.count; // fill sequentially
        } else {
            newIndex = (obs.index + 1) % OBSERVATION_COUNT; // rotate
        }

        obs.observations[newIndex] = Observation({
            timestamp: uint32(block.timestamp),
            price: price
        });

        obs.index = newIndex;
        if (obs.count < OBSERVATION_COUNT) obs.count++;

        lastUpdateTime[queryToken] = uint32(block.timestamp);
        emit PriceUpdated(queryToken, price, uint32(block.timestamp));
    }

    /**
     * @notice Get current price from Uniswap V2 pair
     * @dev Returns price scaled by 1e18 (Compound expects 1e18 precision)
     */
    function _getCurrentPrice(address pair, address token) private view returns (uint256) {
        IUniswapV2Pair uniswapPair = IUniswapV2Pair(pair);
        address token0 = uniswapPair.token0();
        address token1 = uniswapPair.token1();

        (uint112 reserve0, uint112 reserve1, ) = uniswapPair.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");

        address usdt;
        uint256 reserveToken;
        uint256 reserveUSDT;
        uint8 tokenDecimals;
        uint8 usdtDecimals;

        if (token == token0) {
            usdt = token1;
            reserveToken = reserve0;
            reserveUSDT = reserve1;
        } else if (token == token1) {
            usdt = token0;
            reserveToken = reserve1;
            reserveUSDT = reserve0;
        } else {
            revert("Token not in pair");
        }

        tokenDecimals = EIP20Interface(token).decimals();
        usdtDecimals = EIP20Interface(usdt).decimals();

        // price = (reserveUSDT * 1e18 * 10^tokenDecimals) / (reserveToken * 10^usdtDecimals)
        uint256 numerator = reserveUSDT * 1e18 * (10 ** uint256(tokenDecimals));
        uint256 denominator = reserveToken * (10 ** uint256(usdtDecimals));
        return numerator / denominator;
    }

    /**
     * @notice Set Uniswap V2 pair for a token (token/USDT pair)
     */
    function setPair(address token, address pair) external onlyAdmin {
        require(token != address(0), "Invalid token");
        require(pair != address(0), "Invalid pair");

        IUniswapV2Pair uniswapPair = IUniswapV2Pair(pair);
        address token0 = uniswapPair.token0();
        address token1 = uniswapPair.token1();
        require(token == token0 || token == token1, "Token not in pair");

        (uint112 r0, uint112 r1, ) = uniswapPair.getReserves();
        require(r0 > 0 && r1 > 0, "Pair has no liquidity");

        tokenPairs[token] = pair;
        emit PairSet(token, pair);
    }

    /**
     * @notice Set wrapped token for native token
     */
    function setWrappedToken(address _wrappedToken) external onlyAdmin {
        require(_wrappedToken != address(0), "Invalid wrapped token");
        wrappedToken = _wrappedToken;
        emit WrappedTokenSet(_wrappedToken);
    }

    /**
     * @notice Enable stablecoin for a token (returns fixed price 1e18)
     * @param token The token address to mark as stablecoin
     */
    function enableStablecoin(address token) external onlyAdmin {
        require(token != address(0), "Invalid token");
        isStablecoin[token] = true;
        emit StablecoinEnabled(token);
    }

    /**
     * @notice Disable stablecoin for a token (use TWAP instead)
     * @param token The token address to remove stablecoin status
     */
    function disableStablecoin(address token) external onlyAdmin {
        require(token != address(0), "Invalid token");
        isStablecoin[token] = false;
        emit StablecoinDisabled(token);
    }

    /**
     * @notice Set update interval (seconds)
     */
    function setUpdateInterval(uint32 _updateInterval) external onlyAdmin {
        require(_updateInterval > 0 && _updateInterval <= 3600, "Invalid interval");
        uint32 old = updateInterval;
        updateInterval = _updateInterval;
        emit UpdateIntervalSet(old, _updateInterval);
    }

    /// @notice Event emitted when twap window is changed
    event TwapWindowSet(uint32 oldWindow, uint32 newWindow);

    /**
     * @notice Set TWAP window (seconds)
     */
    function setTwapWindow(uint32 _twapWindow) external onlyAdmin {
        require(_twapWindow > 0, "Invalid twap window");
        uint32 old = twapWindow;
        twapWindow = _twapWindow;
        emit TwapWindowSet(old, _twapWindow);
    }

    /**
     * @notice Transfer admin rights
     */
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin");
        admin = newAdmin;
    }
}
