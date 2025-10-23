// SPDX-License-Identifier: MIT
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

	struct Reserves {
		uint128 reserve0;
		uint128 reserve1;
	}
	/// Reserves
	Reserves public reserves;

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

	function computeExpectedTokensOut(address inputToken, uint256 tokensIn, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public override view returns (uint256 tokensInActual, uint256 tokensOut, uint160 newSqrtPriceX96) {
		uint256 tokensRemaining = tokensIn;
		(uint128 reserve0, uint128 reserve1) = reserves;
		uint256 x0 = uint256(poolPolarity ? reserve0 : reserve1);
		uint256 y0 = uint256(poolPolarity ? reserve1 : reserve0);

		// Convert sqrtPriceX96 and sqrtPriceLimitX96 to 128.128 encoding
		uint256 lastPrice = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		uint256 priceLimit = Math.mulDiv(sqrtPriceLimitX96, sqrtPriceLimitX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		if (!poolPolarity)
			(lastPrice, priceLimit) = (0x100000000000000000000000000000000 / lastPrice, 0x100000000000000000000000000000000 / priceLimit);

		uint256 newPrice;
		if (inputToken == reserve) {
			// Purchasing launch tokens - price will go from initial curve to xyk curve

			if (x0 < curveLimit) {
				// Purchasing launch tokens - price will go from initial curve to xyk curve
				uint256 M = priceMultiple / curveLimit;

				// Check if swap stays within initial curve
				uint256 tokensInTmp = tokensIn;
				if (x0 + tokensInTmp > curveLimit)
					// Go to the maximum number of input tokens for this part of the curve
					tokensInTmp = curveLimit - x0;

				// Compute dy = dx / (lastPrice + M * dx / 2)
				uint256 denominator = lastPrice + ((M * tokensInTmp) >> 1);
				tokensOut = Math.mulDiv(tokensInTmp, 0x100000000000000000000000000000000, denominator);

				// Calculate new price: P = lastPrice + M * dx
				newPrice = lastPrice + M * tokensInTmp;

				if (newPrice > priceLimit)
					// Price exceeds limit, compute at price limit
					// We also specify here that no more tokens remain for swapping, since the price limit was reached
					(tokensOut, newPrice, tokensRemaining) = (, priceLimit, 0);
				else
					// Compute the number of unconverted tokens
					tokensRemaining -= tokensInTmp;
			} else
				tokensIn = 0;

			if (tokensRemaining > 0) {
				// Compute for (x + b)y = k
				//   vx = x + b (virtual liquidity x)
				//   b = curveLimit
				uint256 vx = uint256(x0 + curveLimit);
				uint256 K = vx * uint256(y0);
				uint256 y1 = y0 - tokensOut;
				uint256 tokensInTmp = (K / y1) - vx;
				newPrice = Math.mulDiv(0x100000000000000000000000000000000, vx + tokensInTmp, y1);

				if (newPrice > priceLimit) {
					// Price exceeds limit, compute at price limit
					// tokensRemaining doesn't need to be set because it is not checked again
					//   priceLimit = (vx + tokensInTmp) / y1
					//   y1 = K / (vx + tokensInTmp)
					//   priceLimit * y1 = (vx + tokensInTmp)^2
					//   tokensInTmp = sqrt(priceLimit * y1) - vx
					newPrice = priceLimit;
					tokensInTmp = Math.sqrt(Math.mulDiv(priceLimit, y1, 0x100000000000000000000000000000000)) - vx;
				}

				tokensIn += tokensInTmp;
			}
		} else {
			// Selling launch tokens - price will go from xyk curve to initial curve
		}
	}

	function computeExpectedTokensIn(address inputToken, uint256 tokensOut, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public override view returns (uint256 tokensIn, uint256 tokensOutActual, uint160 newSqrtPriceX96) {
		uint256 tokensRemaining = tokensOut;
		(uint128 reserve0, uint128 reserve1) = reserves;
		uint256 x0 = uint256(poolPolarity ? reserve0 : reserve1);
		uint256 y0 = uint256(poolPolarity ? reserve1 : reserve0);

		// Convert sqrtPriceX96 and sqrtPriceLimitX96 to 128.128 encoding
		uint256 lastPrice = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		uint256 priceLimit = Math.mulDiv(sqrtPriceLimitX96, sqrtPriceLimitX96, 0x10000000000000000 /* 1 << (192 - 128) */);
		if (!poolPolarity)
			(lastPrice, priceLimit) = (0x100000000000000000000000000000000 / lastPrice, 0x100000000000000000000000000000000 / priceLimit);

		uint256 newPrice;
		if (inputToken == reserve) {
			require(y0 > tokensOut, "IL");

			if (x0 < curveLimit) {
				// Purchasing launch tokens - price will go from initial curve to xyk curve
				uint256 M = priceMultiple / curveLimit;

				// Compute dx = dy * lastPrice / (1 - M * dy / 2)
				uint256 denominator = 0x100000000000000000000000000000000 - ((M * tokensRemaining) >> 1);
				tokensIn = Math.mulDiv(tokensRemaining, lastPrice, denominator);

				// Check if swap stays within initial curve
				if (x0 + tokensIn > curveLimit)
					// Go to the maximum number of input tokens for this part of the curve
					tokensIn = curveLimit - x0;

				// Calculate new price: P = lastPrice + M * dx
				newPrice = lastPrice + M * tokensIn;

				if (newPrice > priceLimit)
					// Price exceeds limit, compute at price limit
					// We also specify here that no more tokens remain for swapping, since the price limit was reached
					(tokensIn, newPrice, tokensRemaining) = ((priceLimit - lastPrice) / M, priceLimit, 0);
				else {
					// dy = dx / (lastPrice + M * dx / 2)
					uint256 tokensOutTmp = Math.mulDiv(tokensIn, 0x100000000000000000000000000000000, lastPrice + ((M * tokensIn) >> 1));

					// Compute the number of unconverted tokens
					tokensRemaining = tokensOutTmp < tokensRemaining ? tokensRemaining - tokensOutTmp : 0;
				}
			} else
				tokensIn = 0;

			if (tokensRemaining > 0) {
				// Compute for (x + b)y = k
				//   vx = x + b (virtual liquidity x)
				// Note that x now must also contain the tokens 
				uint256 vx = uint256(x0 + b + tokensIn);
				uint256 K = vx * uint256(y0);
				uint256 y1 = y0 - tokensOut;
				uint256 tokensInTmp = (K / y1) - vx;
				newPrice = Math.mulDiv(0x100000000000000000000000000000000, vx + tokensInTmp, y1);

				if (newPrice > priceLimit) {
					// Price exceeds limit, compute at price limit
					// tokensRemaining doesn't need to be set because it is not checked again
					//   priceLimit = (vx + tokensInTmp) / y1
					//   y1 = K / (vx + tokensInTmp)
					//   priceLimit * y1 = (vx + tokensInTmp)^2
					//   tokensInTmp = sqrt(priceLimit * y1) - vx
					newPrice = priceLimit;
					tokensInTmp = Math.sqrt(Math.mulDiv(priceLimit, y1, 0x100000000000000000000000000000000)) - vx;
				}

				tokensIn += tokensInTmp;
			}
		} else {
			// Selling launch tokens - price will go from xyk curve to initial curve
			if (x0 > curveLimit) {

			}
		}

		// Convert to sqrtPriceX96
		newSqrtPriceX96 = uint160(Math.sqrt(newPrice) * (1 << 96));
		if (!poolPolarity)
			newSqrtPriceX96 = 0x100000000000000000000000000000000 / newSqrtPriceX96;
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
			(uint128 reserve0, uint128 reserve1) = reserves;
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
		Reserves memory tmp = reserves;

		// Correct the input amounts to match our reserves
		if (tmp.reserve1 == 0)
			amount1 = 0;
		else if (tmp.reserve0 == 0)
			amount0 = 0;
		else {
			uint256 ratioNeeded = (uint256(tmp.reserve0) << 128) / uint256(tmp.reserve1);
			uint256 ratio = (uint256(amount0) << 128) / uint256(amount1);
			if (ratio > ratioNeeded)
				amount0 = uint128((ratioNeeded * amount1) >> 128);
			else if (ratio < ratioNeeded)
				amount1 = uint128((uint256(amount0) << 128) / ratioNeeded);
		}

		// Update curveLimit
		uint256 ratio = 0x100000000000000000000000000000000 + (poolPolarity ? (uint256(amount0) << 128) / tmp.reserve0 : (uint256(amount1) << 128) / tmp.reserve1);
		curveLimit = Math.mulDiv(curveLimit, ratio, 0x100000000000000000000000000000000);

		require(IERC20(token0).transferFrom(msg.sender, address(this), amount0));
		require(IERC20(token1).transferFrom(msg.sender, address(this), amount1));
		tmp.reserve0 += amount0;
		tmp.reserve1 += amount1;
		reserves = tmp;

		return (amount0, amount1);
	}
}
