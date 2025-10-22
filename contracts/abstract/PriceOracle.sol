// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap v3
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../libs/V3TickMathPorted.sol";
import "../libs/Math.sol";


contract PriceOracle {
	mapping(address => mapping(address => address)) public uniswapV3PoolByToken;
	mapping(address => mapping(address => uint256)) public fixedPriceMap;

	IUniswapV3Factory internal immutable uniswapV3Factory = IUniswapV3Factory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD);

	function setFixedPrice(address base, address quote, uint256 price) internal {
		fixedPriceMap[base][quote] = price;
		fixedPriceMap[quote][base] = (1 << 192) / price;
	}

	function convertUsingTwap(address base, address quote, uint32 duration, uint256 amountBase) internal view returns (uint256 amountQuote) {
		if (base == quote)
			return amountBase;

		uint256 fixedPrice = fixedPriceMap[base][quote];
		if (fixedPrice != 0)
			return Math.mulDiv(fixedPrice, amountBase, 1 << 96);

		address poolAddress = getPreferredPoolFor(base, quote);
		uint160 sqrtPriceX96;
		uint24 shiftAmount;

		unchecked {
			// Get timestamps
			uint32[] memory secondsAgos = new uint32[](2);
			secondsAgos[0] = duration;
			secondsAgos[1] = 0;

			// Observe cumulative tick values
			(int56[] memory tickCumulatives, ) = IUniswapV3Pool(poolAddress).observe(secondsAgos);

			// Calculate average tick over the interval
			int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(duration)));

			// Convert average tick to sqrtPriceX96
			sqrtPriceX96 = correctPriceDirection(base, quote, TickMath.getSqrtRatioAtTick(avgTick));

			// We use shifting to reduce overflow risk
			// If it still overflows (highly unlikely, requires incredibly high prices and amounts),
			// then this call will revert.
			shiftAmount = (amountBase >> 96) != 0 ? 64 : 0;
		}

		return Math.mulDiv(uint256(sqrtPriceX96) * (amountBase >> shiftAmount), uint256(sqrtPriceX96), 1 << (192 - shiftAmount));
	}

	function getPreferredPoolFor(address a, address b) internal view returns (address pool) {
		// Check argument order
		if (a > b)
			(a, b) = (b, a);

		// First try the cache
		pool = uniswapV3PoolByToken[a][b];

		// No pool found = revert
		require(pool != address(0), "Unknown pair");
	}

	// Primary should either be USDC or address(0), indicating Eth.  This will save the contract address
	// for the pool this contract can use later. 
	function findV3PoolFor(address base, address quote, uint256 amountInQuote) internal returns (address bestPool) {
		uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];

		uint128 bestLiquidity = 0;
		uint160 sqrtPriceX96;
		uint16 observationCardinalityNext;

		for (uint8 i = 0; i < fees.length; i++) {
			address pool;
			if (base < quote)
				pool = uniswapV3Factory.getPool(base, quote, fees[i]);
			else
				pool = uniswapV3Factory.getPool(quote, base, fees[i]);

			if (pool == address(0))
				continue;

			uint128 liquidity = IUniswapV3Pool(pool).liquidity();
			if (liquidity > bestLiquidity) {
				bestLiquidity = liquidity;
				bestPool = pool;
				(sqrtPriceX96,,,,observationCardinalityNext,,) = IUniswapV3Pool(pool).slot0();
			}
		}

		require(bestPool != address(0), "No pools found");

		// We don't want our trades to move the pool price by more than 1%
		// This computes the prices based on the square root of 0.5% movements
		// in each direction, since the prices are in rooted units, and for a
		// cumulative rate of 1%.
		uint160 sqrtPriceX96High = uint160(uint256(sqrtPriceX96) * 10025 / 10000);
		uint160 sqrtPriceX96Low = uint160(uint256(sqrtPriceX96) * 9975 / 10000);
		uint256 amount;
		if (base > quote)
			amount = getAmount0ForLiquidity(sqrtPriceX96Low, sqrtPriceX96High, bestLiquidity);
		else
			amount = getAmount1ForLiquidity(sqrtPriceX96Low, sqrtPriceX96High, bestLiquidity);

		require(amount > amountInQuote, "Not enough liquidity in any visible pool");

		if (base > quote)
			uniswapV3PoolByToken[quote][base] = bestPool;
		else
			uniswapV3PoolByToken[base][quote] = bestPool;

		// Check cardinality
		if (observationCardinalityNext < 10)
			IUniswapV3Pool(bestPool).increaseObservationCardinalityNext(10);
	}

	function addUniswapV3Pool(address _pool) internal returns (address token0, address token1) {
		IUniswapV3Pool pool = IUniswapV3Pool(_pool);
		(,,,,uint16 observationCardinalityNext,,) = pool.slot0();
		token0 = pool.token0();
		token1 = pool.token1();

		uniswapV3PoolByToken[token0][token1] = _pool;

		// Check cardinality
		if (observationCardinalityNext < 10)
			pool.increaseObservationCardinalityNext(10);
	}
	
	/// @notice Computes the amount of token0 for a given amount of liquidity and a price range
	/// @param sqrtRatioAX96 A sqrt price
	/// @param sqrtRatioBX96 Another sqrt price
	/// @param liquidity The liquidity being valued
	/// @return amount0 The amount0
	function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) internal pure returns (uint256 amount0) {
		return Math.mulDiv(
				uint256(liquidity) << 96,  // FixedPoint96.RESOLUTION = 96
				sqrtRatioBX96 - sqrtRatioAX96,
				sqrtRatioBX96
		) / sqrtRatioAX96;
	}


	/// @notice Computes the amount of token1 for a given amount of liquidity and a price range
	/// @param sqrtRatioAX96 A sqrt price
	/// @param sqrtRatioBX96 Another sqrt price
	/// @param liquidity The liquidity being valued
	/// @return amount1 The amount1
	function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) internal pure returns (uint256 amount1) {
		return Math.mulDiv(
				liquidity,
				sqrtRatioBX96 - sqrtRatioAX96,
				0x1000000000000000000000000 // FixedPoint96.Q96
		);
	}

	// For some reason the Uniswap libraries don't have this function, despite it being in the documentation,
	// so I have to go on some block explorer to find the damned source code.
	function getAmountsForLiquidity(uint160 sqrtRatioX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) internal pure returns (uint256 amount0, uint256 amount1) {
		// Never happens in this contract
		//if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

		if (sqrtRatioX96 <= sqrtRatioAX96) {
			// And yet, for SOME REASON, they still included these functions in their library.  Just not the one I need.
			amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
		} else if (sqrtRatioX96 < sqrtRatioBX96) {
			amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
			amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
		} else {
			amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
		}
	}

	function correctPriceDirection(address base, address quote, uint160 sqrtPriceX96) public pure returns (uint160 sqrtPriceX96Corrected) {
		if (base < quote)
			return sqrtPriceX96;
		else
			return uint160((1 << 192) / uint256(sqrtPriceX96));
	}
}
