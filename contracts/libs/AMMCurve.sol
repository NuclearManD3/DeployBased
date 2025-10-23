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
	***    avgPrice = P0 + M * x0 + M * dx / 2
	***    dy = dx / avgPrice = dx / (P0 + M * x0 + M * dx / 2)
	***    avgPrice = lastPrice + M * dx / 2
	***    dy = dx / (lastPrice + M * dx / 2)
	***
	***    dx = dy * lastPrice / (1 - M * dy / 2)
	***
	***
	***    M = priceMultiple / curveLimit
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
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
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
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
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

}


/// K = (x + b) * y
library AMMCurveKxby {
	function computeBuyTokensOut(uint256 maxTokensIn, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
		// b = reserveOffset
		uint256 vx = uint256(x0 + reserveOffset);
		uint256 K = vx * uint256(y0);

		// tokensIn is dx in this regime (caller provides max available)
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
			newPrice = priceLimit;

			// tokensIn such that (vx + tokensIn)/y1 = priceLimit / 2^128
			// => (vx + tokensIn) = sqrt(priceLimit * y1 / 2^128)  (same algebra you used elsewhere)
			// TODO: This is wrong - y1 cannot be used because it would have been polluted by false/hypothetical token input amount
			uint256 tmp = 0;//Math.mulDiv(priceLimit, y1, 0x100000000000000000000000000000000);
			uint256 sqrtv = Math.sqrt(tmp);
			// tokensIn = sqrtv - vx
			tokensIn = sqrtv > vx ? sqrtv - vx : 0;

			// recompute final y1 and tokensOut after that tokensIn
			vx1 = vx + tokensIn;
			uint256 y1 = K / vx1;
			tokensOut = y0 - y1;
			return (tokensIn, tokensOut, newPrice);
		} else
			return (tokensIn, y0 - K / vx1, newPrice);
	}

	function computeBuyTokensIn(uint256 maxTokensOut, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) internal pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
		// Compute for (x + b)y = k
		//   vx = x + b (virtual liquidity x)
		//   b = reserveOffset
		uint256 vx = uint256(x0 + reserveOffset);
		uint256 K = vx * uint256(y0);
		uint256 y1 = y0 - maxTokensOut;
		tokensOut = maxTokensOut;
		tokensIn = (K / y1) - vx;
		newPrice = Math.mulDiv(0x100000000000000000000000000000000, vx + tokensIn, y1);

		if (newPrice > priceLimit) {
			// Price exceeds limit, compute at price limit
			newPrice = priceLimit;
			tokensIn = Math.sqrt(Math.mulDiv(priceLimit, y1, 0x100000000000000000000000000000000)) - vx;
			tokensOut = y0 - (K / (tokensIn + vx));
			return (tokensIn, tokensOut, newPrice);
		}

		return (tokensIn, tokensOut, newPrice);
	}
}