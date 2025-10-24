// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../libs/AMMCurve.sol";


contract AMMCurveTest {

	function AMMCurveKxbybasicComputeBuyTokensAt(uint256 K, uint256 vx, uint256 y0, uint256 price) public pure returns (uint256, uint256) {
		return AMMCurveKxby.basicComputeBuyTokensAt(K, vx, y0, price);
	}

	function AMMCurveKxbybasicComputeSellTokensAt(uint256 K, uint256 vx, uint256 y0, uint256 price) public pure returns (uint256, uint256) {
		return AMMCurveKxby.basicComputeSellTokensAt(K, vx, y0, price);
	}

	function AMMCurveKxbycomputeBuyTokensOut(uint256 maxTokensIn, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) public pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
		return AMMCurveKxby.computeBuyTokensOut(maxTokensIn, reserveOffset, x0, y0, priceLimit);
	}

	function AMMCurveKxbycomputeBuyTokensIn(uint256 maxTokensOut, uint256 reserveOffset, uint256 x0, uint256 y0, uint256 priceLimit) public pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
		return AMMCurveKxby.computeBuyTokensIn(maxTokensOut, reserveOffset, x0, y0, priceLimit);
	}

	function AMMCurvePMxbasicBuyTokensOut(uint256 tokensIn, uint256 lastPrice, uint256 M) public pure returns (uint256 tokensOut) {
		return AMMCurvePMx.basicBuyTokensOut(tokensIn, lastPrice, M);
	}

	function AMMCurvePMxbasicBuyTokensIn(uint256 tokensOut, uint256 lastPrice, uint256 M) public pure returns (uint256 tokensIn) {
		return AMMCurvePMx.basicBuyTokensIn(tokensOut, lastPrice, M);
	}

	function AMMCurvePMxbasicSellTokensOut(uint256 tokensIn, uint256 lastPrice, uint256 M) public pure returns (uint256 tokensOut) {
		return AMMCurvePMx.basicSellTokensOut(tokensIn, lastPrice, M);
	}

	function AMMCurvePMxbasicSellTokensIn(uint256 tokensOut, uint256 lastPrice, uint256 M) public pure returns (uint256 tokensIn) {
		return AMMCurvePMx.basicSellTokensIn(tokensOut, lastPrice, M);
	}

	function AMMCurvePMxcomputeBuyTokensOut(uint256 maxTokensIn, uint256 priceMultiple, uint256 curveLimit, uint256 x0, uint256 priceLimit, uint256 lastPrice) public pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
		return AMMCurvePMx.computeBuyTokensOut(maxTokensIn, priceMultiple, curveLimit, x0, priceLimit, lastPrice);
	}

	function AMMCurvePMxcomputeBuyTokensIn(uint256 maxTokensOut, uint256 priceMultiple, uint256 curveLimit, uint256 x0, uint256 priceLimit, uint256 lastPrice) public pure
		returns (uint256 tokensIn, uint256 tokensOut, uint256 newPrice) {
		return AMMCurvePMx.computeBuyTokensIn(maxTokensOut, priceMultiple, curveLimit, x0, priceLimit, lastPrice);
	}
}
