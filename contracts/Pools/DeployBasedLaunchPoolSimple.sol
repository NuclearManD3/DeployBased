// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;


import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";

import "../abstract/ERC20.sol";

import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/ICompoundPool.sol";
import "../interfaces/IDeployBasedPoolFactory.sol";
import "../interfaces/IERC20.sol";

import "../libs/Math.sol";
import "../libs/UniswapV3Lib.sol";
import "../libs/AMMCurve.sol";

import "../abstract/UniswapV3PoolEmulator.sol";
import "../abstract/ownable.sol";


struct LaunchPoolInitParams {
	/// Lending pool for earning
	address lendingPoolAddress;

	/// How fast the price will rise for the initial curve
	/// P = minimumPrice + priceMultiple * reserveTokensHeld / curveLimit
	uint96 priceMultiple;

	/// Starting price
	uint160 sqrtPriceX96;

	/// Amount of reserve tokens needed to switch to xy = k mode
	/// Donation can modify this number after initialization
	uint96 curveLimit;

	/// Amount of launch tokens to add to the pool
	uint128 initialLaunchTokens;

	/// Initial reserve offset, recomputed on donate
	uint128 reserveOffset;
}


/// There are two types of tokens:
///  1. A launch token
///  2. A reserve token
/// The pool vends out the launch token in exchange for reserve tokens,
/// and the reserve tokens are lent out on Compound to earn yield.
///
/// There are two price models, which automatically switch at a certain price.
/// This allows the pool to accumulate liquidity before switching to xy = k,
/// so that price impact can be reduced.
///
/// When reserve tokens reach curveLimit, the curve switches to `xy = k`.
/// If reserve tokens are less than curveLimit, then the alternative model
/// is used:
///
///  dy = (dx^2) / (dx*P0 + M * ((x0 + dx)^2 - x0^2))
///
/// For now I have removed support for concentrated liquidity, since it adds a lot of
/// complexity and I am trying to build a prototype quickly.


contract DeployBasedLaunchPool is UniswapV3PoolEmulator, Ownable {
	address public immutable reserve;
	address public immutable launch;
	ICompoundV3Pool public immutable lendingPool;
	/// @dev `poolPolarity = (reserve == token0)`  This is true if `zeroForOne` indicates purchase of `launch`
	bool internal immutable poolPolarity;

	// CURVE CONFIGURATION
	// This is the minimum price in reserve per launch, 128.128 format
	uint256 immutable public minimumPrice128128;
	/// How fast the price will rise for the initial curve
	/// P = minimumPrice + priceMultiple * reserveTokensHeld / curveLimit
	/// Encoded in 128.128 form
	uint256 immutable internal priceMultiple;
	/// Amount of reserve tokens needed to switch to xy = k mode
	uint256 internal curveLimit;
	/// b term in (x + b)y = k
	uint256 internal reserveOffset;

	uint128 immutable internal initialLaunchTokens;
	function liquidity() public override view returns (uint128) {
		return uint128(curveLimit * Math.sqrt(initialLaunchTokens));
	}

	uint256 internal _reserves;
	function reserves() public view returns (uint128, uint128) {
		uint256 tmp = _reserves;
		return (uint128(tmp & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF), uint128(tmp >> 128));
	}
	function setReserves(uint256 a, uint256 b) internal {
		require((a >> 128) == 0 && (b >> 128) == 0);
		_reserves = a | (b << 128);
	}

	function feeGrowthGlobal0X128() public override view returns (uint256) {
		return 0; //Math.mulDiv(balance(token0) + claimedFees0, 1 << 128, liquidity);
	}

	function feeGrowthGlobal1X128() public override view returns (uint256) {
		return 0; //Math.mulDiv(balance(token1) + claimedFees1, 1 << 128, liquidity);
	}

	/// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
	modifier onlyFactoryOwner() {
		require(msg.sender == IDeployBasedPoolFactory(factory).owner());
		_;
	}

	constructor(address _reserve, address _launch, uint24 _fee, LaunchPoolInitParams memory initParams)
		UniswapV3PoolEmulator(initParams.sqrtPriceX96, msg.sender, _reserve, _launch, _fee) {

		// Initialize immutables
		(reserve, launch, lendingPool) = (_reserve, _launch, ICompoundV3Pool(initParams.lendingPoolAddress));
		priceMultiple = uint256(initParams.priceMultiple);
		curveLimit = uint256(initParams.curveLimit);
		reserveOffset = uint256(initParams.reserveOffset);

		uint256 priceTmp = initParams.sqrtPriceX96;
		priceTmp = Math.mulDiv(priceTmp, priceTmp, 0x10000000000000000 /* 1 << (192 - 128) */);
		if (_launch < _reserve) {
			poolPolarity = false;
			priceTmp = 0x100000000000000000000000000000000 / priceTmp;
		} else {
			poolPolarity = true;
		}

		minimumPrice128128 = priceTmp;
	}

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
	***  Usage of y0 should be avoided.
	***
	**/

	function computeExpectedTokensOut(address inputToken, uint256 maxTokensIn, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public override view returns (uint256 tokensIn, uint256 tokensOut, uint160 newSqrtPriceX96) {
		uint256 x0;
		uint256 y0;
		{
			(uint128 reserve0, uint128 reserve1) = reserves();
			x0 = uint256(poolPolarity ? reserve0 : reserve1);
			y0 = uint256(poolPolarity ? reserve1 : reserve0);
		}

		// Convert sqrtPriceX96 and sqrtPriceLimitX96 to 128.128 encoding
		uint256 lastPrice = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		uint256 priceLimit = Math.mulDiv(sqrtPriceLimitX96, sqrtPriceLimitX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		if (!poolPolarity)
			(lastPrice, priceLimit) = (0x100000000000000000000000000000000 / lastPrice, 0x100000000000000000000000000000000 / priceLimit);

		uint256 newPrice;
		if (inputToken == reserve) {
			// Purchasing launch tokens - price will go from initial curve to xyk curve

			if (x0 < curveLimit)
				(tokensIn, tokensOut, newPrice) = AMMCurvePMx.computeBuyTokensOut(maxTokensIn, priceMultiple, curveLimit, x0, priceLimit, lastPrice);
			else
				(tokensIn, tokensOut, newPrice) = (0, 0, lastPrice);

			if (maxTokensIn > tokensIn && newPrice < priceLimit) {
				uint256 remainingIn = maxTokensIn - tokensIn;
				uint256 newX = x0 + tokensIn;
				uint256 newY = y0 - tokensOut;
				(uint256 tokensInNext, uint256 tokensOutNext, uint256 nextPrice) = AMMCurveKxby.computeBuyTokensOut(remainingIn, curveLimit, newX, newY, priceLimit);
				tokensIn += tokensInNext;
				tokensOut += tokensOutNext;
				newPrice = nextPrice;
			}
		} else {
			// Selling launch tokens - price will go from xyk curve to initial curve

			if (x0 > curveLimit)
				(tokensIn, tokensOut, newPrice) = AMMCurveKxby.computeSellTokensOut(maxTokensIn, curveLimit, x0, y0, priceLimit);
			else
				(tokensIn, tokensOut, newPrice) = (0, 0, lastPrice);

			if (maxTokensIn > tokensIn && newPrice > priceLimit) {
				uint256 remainingIn = maxTokensIn - tokensIn;
				uint256 newX = x0 - tokensOut;
				(uint256 tokensInNext, uint256 tokensOutNext, uint256 nextPrice) = AMMCurvePMx.computeSellTokensOut(remainingIn, priceMultiple, curveLimit, newX, priceLimit, newPrice);
				tokensIn += tokensInNext;
				tokensOut += tokensOutNext;
				newPrice = nextPrice;
			}
		}

		// Convert to sqrtPriceX96
		newSqrtPriceX96 = uint160(Math.sqrt(newPrice) << 32);
		if (!poolPolarity)
			newSqrtPriceX96 = uint160(uint256(0x1000000000000000000000000000000000000000000000000) / uint256(newSqrtPriceX96));
	}

	function computeExpectedTokensIn(address inputToken, uint256 maxTokensOut, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public override view returns (uint256 tokensIn, uint256 tokensOut, uint160 newSqrtPriceX96) {
		uint256 x0;
		uint256 y0;
		{
			(uint128 reserve0, uint128 reserve1) = reserves();
			x0 = uint256(poolPolarity ? reserve0 : reserve1);
			y0 = uint256(poolPolarity ? reserve1 : reserve0);
		}

		// Convert sqrtPriceX96 and sqrtPriceLimitX96 to 128.128 encoding
		uint256 lastPrice = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		uint256 priceLimit = Math.mulDiv(sqrtPriceLimitX96, sqrtPriceLimitX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		if (!poolPolarity)
			(lastPrice, priceLimit) = (0x100000000000000000000000000000000 / lastPrice, 0x100000000000000000000000000000000 / priceLimit);

		uint256 newPrice;
		if (inputToken == reserve) {
			// Purchasing launch tokens - price will go from initial curve to xyk curve

			if (x0 < curveLimit)
				(tokensIn, tokensOut, newPrice) = AMMCurvePMx.computeBuyTokensIn(maxTokensOut, priceMultiple, curveLimit, x0, priceLimit, lastPrice);
			else
				(tokensIn, tokensOut, newPrice) = (0, 0, lastPrice);

			if (maxTokensOut > tokensOut && newPrice < priceLimit) {
				uint256 remainingOut = maxTokensOut - tokensOut;
				uint256 newX = x0 + tokensIn;
				uint256 newY = y0 - tokensOut;
				(uint256 tokensInNext, uint256 tokensOutNext, uint256 nextPrice) = AMMCurveKxby.computeBuyTokensIn(remainingOut, curveLimit, newX, newY, priceLimit);
				tokensIn += tokensInNext;
				tokensOut += tokensOutNext;
				newPrice = nextPrice;
			}
		} else {
			// Selling launch tokens - price will go from xyk curve to initial curve

			if (x0 > curveLimit)
				(tokensIn, tokensOut, newPrice) = AMMCurveKxby.computeSellTokensIn(maxTokensOut, curveLimit, x0, y0, priceLimit);
			else
				(tokensIn, tokensOut, newPrice) = (0, 0, lastPrice);

			if (maxTokensOut > tokensOut && newPrice > priceLimit) {
				uint256 remainingOut = maxTokensOut - tokensOut;
				uint256 newX = x0 - tokensOut;
				(uint256 tokensInNext, uint256 tokensOutNext, uint256 nextPrice) = AMMCurvePMx.computeSellTokensIn(remainingOut, priceMultiple, curveLimit, newX, priceLimit, newPrice);
				tokensIn += tokensInNext;
				tokensOut += tokensOutNext;
				newPrice = nextPrice;
			}
		}

		// Convert to sqrtPriceX96
		newSqrtPriceX96 = uint160(Math.sqrt(newPrice) << 32);
		if (!poolPolarity)
			newSqrtPriceX96 = uint160(uint256(0x1000000000000000000000000000000000000000000000000) / uint256(newSqrtPriceX96));
	}

	function payTokensToSwapper(address token, uint256 amount, address recipient) internal override {
		if (token == reserve)
			lendingPool.withdrawTo(recipient, reserve, amount);
		else
			require(IERC20(token).transfer(recipient, amount));
	}

	function acceptTokensFromSwapper(address token, uint256 amount) internal override {
		if (token == reserve) {
			amount = IERC20(reserve).balanceOf(address(this));
			IERC20(reserve).approve(address(lendingPool), amount);
			lendingPool.supply(reserve, amount);
		}
	}

	/// @param token the token to get a balance of
	/// @dev Get the pool's balance of a given token
	/// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
	/// check
	/// @dev This function also checks if the token is the reserve token, and adds the balance of
	/// lending pool tokens in this case.
	function balance(address token) internal override view returns (uint256) {
		uint256 total = 0;
		if (token == reserve) {
			(bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
			require(success && data.length >= 32);
			total = abi.decode(data, (uint256));
			token = address(lendingPool);
		}

		(bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
		require(success && data.length >= 32);
		total += abi.decode(data, (uint256));
		return total;
	}

	function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) external override lock onlyOwner returns (uint128, uint128) {
		uint256 amount0 = balance(token0);
		uint256 amount1 = balance(token1);
		{
			(uint128 reserve0, uint128 reserve1) = reserves();
			amount0 -= uint256(reserve0);
			amount1 -= uint256(reserve1);
		}
		uint256 protocolFee0 = amount0 >> 3;
		uint256 protocolFee1 = amount1 >> 3;
		payTokensToSwapper(token0, amount0 - protocolFee0, recipient);
		payTokensToSwapper(token1, amount1 - protocolFee1, recipient);
		payTokensToSwapper(token0, protocolFee0, factory);
		payTokensToSwapper(token1, protocolFee1, factory);

		return (uint128(amount0 - protocolFee0), uint128(amount1 - protocolFee1));
	}

	function donate(uint128 amount0, uint128 amount1) external lock returns (uint128, uint128) {
		(uint128 reserve0, uint128 reserve1) = reserves();

		// Correct the input amounts to match our reserves
		if (reserve1 == 0)
			amount1 = 0;
		else if (reserve0 == 0)
			amount0 = 0;
		else {
			uint256 ratioNeeded = (uint256(reserve0) << 128) / uint256(reserve1);
			uint256 ratio = (uint256(amount0) << 128) / uint256(amount1);
			if (ratio > ratioNeeded)
				amount0 = uint128((ratioNeeded * amount1) >> 128);
			else if (ratio < ratioNeeded)
				amount1 = uint128((uint256(amount0) << 128) / ratioNeeded);
		}

		// Update curveLimit
		uint256 ratio = 0x100000000000000000000000000000000 + (poolPolarity ? (uint256(amount0) << 128) / reserve0 : (uint256(amount1) << 128) / reserve1);
		curveLimit = Math.mulDiv(curveLimit, ratio, 0x100000000000000000000000000000000);

		require(IERC20(token0).transferFrom(msg.sender, address(this), amount0));
		require(IERC20(token1).transferFrom(msg.sender, address(this), amount1));
		reserve0 += amount0;
		reserve1 += amount1;
		setReserves(reserve0, reserve1);

		return (amount0, amount1);
	}
}
