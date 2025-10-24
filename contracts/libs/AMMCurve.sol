// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./Math.sol";


/// @title AMMCurvePMx
/// @notice Implements a linear bonding curve defined by P = P0 + M * x, using 128.128 fixed-point math.
/// @dev M = priceMultiple / curveLimit. All prices and slopes use 128.128 scaling.
///
/// The curve represents a continuously increasing price proportional to token supply.
/// Provides forward (buy tokens out) and inverse (buy tokens in) computations with curve and price limit enforcement.
library AMMCurvePMx {

	/**
	***  SWAP MATH
	***
	***	avgPrice = P0 + M * x0 + M * dx / 2
	***	dy = dx / avgPrice = dx / (P0 + M * x0 + M * dx / 2)
	***	avgPrice = lastPrice + M * dx / 2
	***	dy = dx / (lastPrice + M * dx / 2)
	***
	***	dx = dy * lastPrice / (1 - M * dy / 2)
	***
	***
	***	M = priceMultiple / curveLimit
	***
	***  Note that M and P0 are in 128.128 form, for precision purposes.
	***
	**/

	function basicBuyTokensOut(uint256 tokensIn, uint256 lastPrice, uint256 M) internal pure returns (uint256 tokensOut) {
		// Verified correct
		uint256 denominator = lastPrice + ((M * tokensIn) >> 1);
		return Math.mulDiv(tokensIn, 0x100000000000000000000000000000000, denominator);
	}

	function basicBuyTokensIn(uint256 tokensOut, uint256 lastPrice, uint256 M) internal pure returns (uint256 tokensIn) {
		// Verified correct
		uint256 denominator = 0x100000000000000000000000000000000 - ((M * tokensOut) >> 1);
		return Math.mulDiv(tokensOut, lastPrice, denominator);
	}

	function basicSellTokensOut(uint256 tokensIn, uint256 lastPrice, uint256 M) internal pure returns (uint256 tokensOut) {
		// Verified correct
		uint256 denominator = 0x100000000000000000000000000000000 + ((M * tokensIn) >> 1);
		return Math.mulDiv(tokensIn, lastPrice, denominator);
	}

	function basicSellTokensIn(uint256 tokensOut, uint256 lastPrice, uint256 M) internal pure returns (uint256 tokensIn) {
		// Verified correct
		uint256 denominator = lastPrice - ((M * tokensOut) >> 1);
		return Math.mulDiv(tokensOut, 0x100000000000000000000000000000000, denominator);
	}

	/**
	 * @notice Computes the actual tokensOut and newPrice for a buy within curve and price limits.
	 * @dev Enforces curve limit and price limit.
	 * @param maxTokensIn Maximum input tokens allowed.
	 * @param priceMultiple Linear price scale factor.
	 * @param curveLimit Total supply limit of the curve.
	 * @param x0 Current x (supply already consumed).
	 * @param priceLimit Maximum price allowed for this operation.
	 * @param lastPrice Price before this operation (128.128).
	 * @return tokensIn Actual tokens spent.
	 * @return tokensOut Tokens received.
	 * @return newPrice Resulting price after the trade.
	 */
	function computeBuyTokensOut(uint256 maxTokensIn, uint256 priceMultiple, uint256 curveLimit, uint256 x0, uint256 priceLimit, uint256 lastPrice) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		// Verified correct
		uint256 M = priceMultiple / curveLimit;

		// Check if swap stays within curve
		if (x0 + maxTokensIn > curveLimit)
			// Go to the maximum number of input tokens for this part of the curve
			maxTokensIn = curveLimit - x0;

		// Compute dy = dx / (lastPrice + M * dx / 2)
		tokensOut = basicBuyTokensOut(maxTokensIn, lastPrice, M);

		// Calculate new price: P = lastPrice + M * dx
		newPrice = lastPrice + M * maxTokensIn;

		if (newPrice > priceLimit) {
			// Price exceeds limit, compute at price limit
			//   price = lastPrice + M * tokensIn
			//   tokensIn = (price - lastPrice) / M
			tokensIn = (priceLimit - lastPrice) / M;
			tokensOut = basicBuyTokensOut(tokensIn, lastPrice, M);
			return (tokensIn, tokensOut, priceLimit);
		} else
			return (maxTokensIn, tokensOut, newPrice);
	}

	/**
	 * @notice Computes tokensIn required to buy up to maxTokensOut, with curve and price limits.
	 * @dev Enforces curve limit and price limit.
	 * @param maxTokensOut Desired output tokens.
	 * @param priceMultiple Linear price scale factor.
	 * @param curveLimit Total curve limit.
	 * @param x0 Current x (supply already consumed).
	 * @param priceLimit Maximum price allowed for this operation.
	 * @param lastPrice Price before this operation (128.128).
	 * @return tokensIn Input tokens required.
	 * @return tokensOut Output tokens obtained (may be lower than requested if limit reached).
	 * @return newPrice Resulting price after trade.
	 */
	function computeBuyTokensIn(uint256 maxTokensOut, uint256 priceMultiple, uint256 curveLimit, uint256 x0, uint256 priceLimit, uint256 lastPrice) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		// This is checked and looks correct, untested
		uint256 M = priceMultiple / curveLimit;

		//   dy * lastPrice + dy * M * dx / 2 = dx
		//   dy * lastPrice = dx * (1 - dy * M / 2)
		//   dx = dy * lastPrice / (1 - dy * M / 2)

		tokensIn = basicBuyTokensIn(maxTokensOut, lastPrice, M);

		// cap so we don't go past the curve limit
		if (x0 + tokensIn > curveLimit) {
			tokensIn = curveLimit - x0;
			tokensOut = basicBuyTokensOut(tokensIn, lastPrice, M);
		} else
			tokensOut = maxTokensOut;

		// new price if we consume tokensIn
		newPrice = lastPrice + M * tokensIn;

		// if new price would exceed the price limit, compute dx that reaches the limit
		if (newPrice > priceLimit) {
			tokensIn = (priceLimit - lastPrice) / M;
			newPrice = priceLimit;

			// recompute tokensOut produced by that dx
			return (tokensIn, basicBuyTokensOut(tokensIn, lastPrice, M), newPrice);
		} else
			return (tokensIn, tokensOut, newPrice);
	}

	/**
	* @notice Computes the actual tokensOut and newPrice for a sell within curve and price limits.
	* @dev Enforces curve limit and price limit. Selling launch tokens (Y) to receive reserve tokens (X).
	* @param maxTokensIn Maximum launch tokens (Y) to sell.
	* @param priceMultiple Linear price scale factor.
	* @param curveLimit Total supply limit of the curve.
	* @param x0 Current x (supply already consumed).
	* @param priceLimit Minimum price allowed for this operation (128.128).
	* @param lastPrice Price before this operation (128.128).
	* @return tokensIn Actual launch tokens (Y) sold.
	* @return tokensOut Reserve tokens (X) received.
	* @return newPrice Resulting price after the trade.
	*/
	function computeSellTokensOut(uint256 maxTokensIn, uint256 priceMultiple, uint256 curveLimit, uint256 x0, uint256 priceLimit, uint256 lastPrice) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		uint256 M = priceMultiple / curveLimit;

		// Ensure we don't sell more tokens than available (x0 is the current supply)
		if (maxTokensIn > x0)
			maxTokensIn = x0;

		// Compute tokensOut: dy = dx * lastPrice / (1 + M * dx / 2)
		tokensOut = basicSellTokensOut(maxTokensIn, lastPrice, M);

		// Calculate new price: P = lastPrice - M * dx (price decreases as supply decreases)
		newPrice = lastPrice - M * maxTokensIn;

		// Enforce price limit (price cannot drop below priceLimit)
		if (newPrice < priceLimit) {
			// Compute tokensIn to reach priceLimit: tokensIn = (lastPrice - priceLimit) / M
			tokensIn = (lastPrice - priceLimit) / M;
			tokensOut = basicSellTokensOut(tokensIn, lastPrice, M);
			return (tokensIn, tokensOut, priceLimit);
		} else
			return (maxTokensIn, tokensOut, newPrice);
	}

	/**
	* @notice Computes tokensIn required to sell to receive up to maxTokensOut, with curve and price limits.
	* @dev Enforces curve limit and price limit. Selling launch tokens (Y) to receive reserve tokens (X).
	* @param maxTokensOut Desired reserve tokens (X) to receive.
	* @param priceMultiple Linear price scale factor.
	* @param curveLimit Total supply limit of the curve.
	* @param x0 Current x (supply already consumed).
	* @param priceLimit Minimum price allowed for this operation (128.128).
	* @param lastPrice Price before this operation (128.128).
	* @return tokensIn Launch tokens (Y) required to sell.
	* @return tokensOut Reserve tokens (X) obtained (may be lower than requested if limit reached).
	* @return newPrice Resulting price after trade.
	*/
	function computeSellTokensIn(uint256 maxTokensOut, uint256 priceMultiple, uint256 curveLimit, uint256 x0, uint256 priceLimit, uint256 lastPrice) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		uint256 M = priceMultiple / curveLimit;

		// Compute tokensIn: dx = dy * (1 + M * dy / 2) / lastPrice
		tokensIn = basicSellTokensIn(maxTokensOut, lastPrice, M);

		// Ensure we don't sell more tokens than available (x0 is the current supply)
		if (tokensIn > x0) {
			tokensIn = x0;
			tokensOut = basicSellTokensOut(tokensIn, lastPrice, M);
		} else {
			tokensOut = maxTokensOut;
		}

		// Calculate new price: P = lastPrice - M * dx
		newPrice = lastPrice - M * tokensIn;

		// Enforce price limit (price cannot drop below priceLimit)
		if (newPrice < priceLimit) {
			// Compute tokensIn to reach priceLimit: tokensIn = (lastPrice - priceLimit) / M
			tokensIn = (lastPrice - priceLimit) / M;
			tokensOut = basicSellTokensOut(tokensIn, lastPrice, M);
			newPrice = priceLimit;
		}

		return (tokensIn, tokensOut, newPrice);
	}
}


// @title AMMCurveKxby
/// @notice Implements an AMM with a constant product curve K = (x + b) * y, using 128.128 fixed-point math.
/// @dev The curve uses a virtual reserve offset (b = reserveOffset) to shift the x-axis, representing K = (x + b) * y.
/// Prices are in 128.128 format for precision. Provides buy and sell computations with price limit enforcement.
library AMMCurveKxby {
	function basicComputeBuyTokensAt(uint256 K, uint256 vx, uint256 y0, uint256 price) internal pure returns (uint256 tokensIn, uint256 tokensOut) {
		unchecked {
			// Price = (vx + dx) / y1 = priceLimit / 2^128
			// y1 = K / (vx + dx)
			// => (vx + dx) / (K / (vx + dx)) = priceLimit / 2^128
			// => (vx + dx)^2 = K * (priceLimit / 2^128)
			// => vx + dx = sqrt(K * priceLimit / 2^128)
			// => dx = sqrt(K * priceLimit / 2^128) - vx
			uint256 tmp = Math.mulDiv(K, price, 0x100000000000000000000000000000000);
			uint256 sqrtv = Math.sqrt(tmp);
			tokensIn = sqrtv > vx ? sqrtv - vx : 0;
		}

		// Recompute y1 and tokensOut with adjusted tokensIn
		uint256 vx1 = vx + tokensIn;
		tokensOut = y0 - (K / vx1);
	}

	function basicComputeSellTokensAt(uint256 K, uint256 vx, uint256 y0, uint256 price) internal pure returns (uint256 tokensIn, uint256 tokensOut) {
		unchecked {
			// Price = vx1 / y1 = priceLimit / 2^128
			// => vx1 / (y0 + dy) = priceLimit / 2^128
			// => vx1 = (y0 + dy) * (priceLimit / 2^128)
			// => K / (y0 + dy) = (y0 + dy) * (priceLimit / 2^128)
			// => (y0 + dy)^2 = K * (2^128 / priceLimit)
			// => y0 + dy = sqrt(K * 2^128 / priceLimit)
			// => dy = sqrt(K * 2^128 / priceLimit) - y0
			uint256 tmp = Math.mulDiv(K, 0x100000000000000000000000000000000, price);
			uint256 sqrtv = Math.sqrt(tmp);
			tokensIn = sqrtv > y0 ? sqrtv - y0 : 0;
		}

		// Recompute vx1 and tokensOut with adjusted tokensIn
		uint256 vx1 = K / (y0 + tokensIn);
		tokensOut = vx > vx1 ? vx - vx1 : 0;
	}

	/**
	 * @notice Computes tokensOut for buying tokens with up to maxTokensIn, respecting price limits.
	 * @dev Uses K = (x + b) * y, where b = reserveOffset, x = reserve tokens, y = launch tokens.
	 * @param maxTokensIn Maximum reserve tokens (x) to input.
	 * @param reserveOffset Virtual reserve offset (b) for the curve.
	 * @param x0 Current reserve token supply (x).
	 * @param y0 Current launch token supply (y).
	 * @param priceLimit Maximum price allowed (128.128).
	 * @return tokensIn Actual reserve tokens input (x).
	 * @return tokensOut Launch tokens output (y).
	 * @return newPrice Resulting price after trade (128.128).
	 */
	function computeBuyTokensOut(uint256 maxTokensIn, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		// b = reserveOffset
		uint256 vx = x0 + reserveOffset;
		uint256 K = vx * y0;

		// Use maxTokensIn as the default input
		tokensIn = maxTokensIn;

		// After adding tokensIn, virtual x becomes vx + tokensIn
		uint256 vx1 = vx + tokensIn;

		{
			// newPrice = (vx1 / y1) in 128.128 -> (vx1 * 2^128) / y1
			// newPrice = (vx1 / (K / vx1))
			// newPrice = (vx1^2 / K) in 128.128 -> (vx1^2 * 2^128) / K
			uint256 tmp = vx1 << 64;
			newPrice = Math.mulDiv(tmp, tmp, K);
		}

		// If price exceeds the priceLimit, find dx that reaches priceLimit
		if (newPrice > priceLimit) {
			(tokensIn, tokensOut) = basicComputeBuyTokensAt(K, vx, y0, priceLimit);
			return (tokensIn, tokensOut, priceLimit);
		} else
			return (tokensIn, y0 - K / vx1, newPrice);
	}

	/**
	 * @notice Computes tokensIn required to buy up to maxTokensOut, respecting price limits.
	 * @dev Uses K = (x + b) * y, where b = reserveOffset, x = reserve tokens, y = launch tokens.
	 * @param maxTokensOut Desired launch tokens (y) to output.
	 * @param reserveOffset Virtual reserve offset (b) for the curve.
	 * @param x0 Current reserve token supply (x).
	 * @param y0 Current launch token supply (y).
	 * @param priceLimit Maximum price allowed (128.128).
	 * @return tokensIn Reserve tokens input (x).
	 * @return tokensOut Launch tokens output (y).
	 * @return newPrice Resulting price after trade (128.128).
	 */
	function computeBuyTokensIn(uint256 maxTokensOut, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		// Compute for (x + b)y = k
		//   vx = x + b (virtual liquidity x)
		//   b = reserveOffset
		uint256 vx = x0 + reserveOffset;
		uint256 K = vx * y0;
		uint256 y1 = y0 - maxTokensOut;
		tokensIn = (K / y1) - vx;
		newPrice = Math.mulDiv(0x100000000000000000000000000000000, vx + tokensIn, y1);

		// If price exceeds the priceLimit, find dx that reaches priceLimit
		if (newPrice > priceLimit) {
			(tokensIn, tokensOut) = basicComputeBuyTokensAt(K, vx, y0, priceLimit);
			return (tokensIn, tokensOut, priceLimit);
		} else
			return (tokensIn, maxTokensOut, newPrice);
	}

	/**
	 * @notice Computes tokensOut for selling launch tokens to receive reserve tokens, respecting price limits.
	 * @dev Uses K = (x + b) * y, where b = reserveOffset, x = reserve tokens, y = launch tokens.
	 * @param maxTokensIn Maximum launch tokens (y) to sell.
	 * @param reserveOffset Virtual reserve offset (b) for the curve.
	 * @param x0 Current reserve token supply (x).
	 * @param y0 Current launch token supply (y).
	 * @param priceLimit Minimum price allowed (128.128).
	 * @return tokensIn Launch tokens input (y).
	 * @return tokensOut Reserve tokens output (x).
	 * @return newPrice Resulting price after trade (128.128).
	 */
	function computeSellTokensOut(uint256 maxTokensIn, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		uint256 vx = x0 + reserveOffset;
		uint256 K = vx * y0;

		// Use maxTokensIn as the default input (launch tokens)
		tokensIn = maxTokensIn;
		// New y: y1 = y0 + dy (selling increases y)
		uint256 y1 = y0 + tokensIn;
		// New virtual x: vx1 = K / y1
		uint256 vx1 = K / y1;
		// Tokens out: dx = vx - vx1 = x0 + b - (K / y1)
		tokensOut = vx > vx1 ? vx - vx1 : 0;
		// New price: (vx1 / y1) in 128.128 = (vx1 * 2^128) / y1
		newPrice = Math.mulDiv(vx1, 0x100000000000000000000000000000000, y1);

		// If price falls below limit, adjust tokensIn to hit priceLimit
		if (newPrice < priceLimit) {
			(tokensIn, tokensOut) = basicComputeSellTokensAt(K, vx, y0, priceLimit);
			newPrice = priceLimit;
			return (tokensIn, tokensOut, priceLimit);
		} else
			return (tokensIn, tokensOut, newPrice);
	}

	/**
	 * @notice Computes tokensIn required to sell to receive up to maxTokensOut reserve tokens, respecting price limits.
	 * @dev Uses K = (x + b) * y, where b = reserveOffset, x = reserve tokens, y = launch tokens.
	 * @param maxTokensOut Desired reserve tokens (x) to output.
	 * @param reserveOffset Virtual reserve offset (b) for the curve.
	 * @param x0 Current reserve token supply (x).
	 * @param y0 Current launch token supply (y).
	 * @param priceLimit Minimum price allowed (128.128).
	 * @return tokensIn Launch tokens input (y).
	 * @return tokensOut Reserve tokens output (x).
	 * @return newPrice Resulting price after trade (128.128).
	 */
	function computeSellTokensIn(uint256 maxTokensOut, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice)
	{
		// Virtual x: vx = x0 + b
		uint256 vx = x0 + reserveOffset;
		// Constant K = (x0 + b) * y0
		uint256 K = vx * y0;
		// New virtual x: vx1 = vx - dy
		uint256 vx1 = vx - maxTokensOut;
		// Tokens in: dy = K / vx1 - y0
		tokensIn = (K / vx1) - y0;
		// Tokens out: dx
		tokensOut = maxTokensOut;
		// New price: (vx1 / y1) in 128.128 = (vx1 * 2^128) / y1
		newPrice = Math.mulDiv(vx1, 0x100000000000000000000000000000000, y0 + tokensIn);

		// If price falls below limit, adjust tokensIn to hit priceLimit
		if (newPrice < priceLimit) {
			(tokensIn, tokensOut) = basicComputeSellTokensAt(K, vx, y0, priceLimit);
			newPrice = priceLimit;
			return (tokensIn, tokensOut, priceLimit);
		} else
			return (tokensIn, tokensOut, newPrice);
	}
}
