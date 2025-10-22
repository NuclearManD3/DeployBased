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
	uint160 immutable public minimumPrice;
	/// How fast the price will rise for the initial curve
	/// P = minimumPrice + priceMultiple * reserveTokensHeld / curveLimit
	/// Encoded in 128.128 form
	uint256 immutable internal priceMultiple;
	/// Amount of reserve tokens needed to switch to xy = k mode
	uint256 internal curveLimit;

	uint128 immutable internal initialLaunchTokens;
	function liquidity() external override view returns (uint128) {
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

	constructor(address _reserve, address _launch, address _lend, uint24 _fee, LaunchPoolInitParams calldata initParams) {
		// Initialize immutables
		(factory, reserve, launch, lendingPool, fee) = (msg.sender, _reserve, _launch, _lend, _fee);
		if (_launch < _reserve)
			(token0, token1, poolPolarity) = (_launch, _reserve, 0);
		else
			(token0, token1, poolPolarity) = (_reserve, _launch, 1);
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

	function computeExpectedTokensOut(address inputToken, uint256 tokensIn, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public override view returns (uint256 tokensOut, uint160 newSqrtPriceX96) {
		if (inputToken == reserve) {
			// Purchasing launch tokens - price will go from initial curve to xyk curve

		} else {
			// Selling launch tokens - price will go from xyk curve to initial curve
		}
	}

	function computeExpectedTokensIn(address inputToken, uint256 tokensOut, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public override view returns (uint256 tokensIn, uint160 newSqrtPriceX96) {
		uint256 tokensRemaining = tokensOut;
		(uint128 reserve0, uint128 reserve1) = reserves;
		uint256 x0 = uint256(poolPolarity ? reserve0 : reserve1);
		uint256 y0 = initialLaunchTokens;

		if (inputToken == reserve) {
			if (reserveAmount < curveLimit) {
				// TODO: Check, simplify, and secure
				// Purchasing launch tokens - price will go from initial curve to xyk curve
				uint256 y = tokensRemaining; // dy, launch tokens out (wei)

				// Convert sqrtPriceX96 to 128.128 encoding
				uint256 lastPrice = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 0x10000000000000000 /* 1 << (192 - 128) */);
				uint256 M = priceMultiple / curveLimit;

				// Compute dx = dy * lastPrice / (1 - M * dy / 2)
				uint256 denominator = 0x100000000000000000000000000000000 - ((M * y) >> 1);
				require(denominator > 0, "Invalid swap: denominator zero");
				tokensIn = Math.mulDiv(y, lastPrice, denominator);
				require(tokensIn > 0, "Invalid swap: zero input");

				// Check if swap stays within initial curve
				if (x0 + tokensIn > curveLimit) {
					// Recompute for the maximum tokens

				} else {
					// Calculate new price: P = lastPrice + M * dx
					uint256 newPrice = lastPrice + M * tokensIn;

					// Convert to sqrtPriceX96
					newSqrtPriceX96 = uint160(Math.sqrt(newPrice) * (1 << 96));

					// Check price limit
					require(newSqrtPriceX96 <= sqrtPriceLimitX96, "Price exceeds limit");
				}

				tokensRemaining = 0; // All tokens processed in initial curve
			}

			if (tokensRemaining > 0) {
				// Compute for xy = k
			}
		} else {
			// Selling launch tokens - price will go from xyk curve to initial curve
		}
	}

	function payTokensToSwapper(address token, uint256 amount, address recipient) internal virtual {
		if (token == reserve)
			lendingPool.withdrawTo(recipient, reserve, amount);
		else
			require(IERC20(token).transfer(recipient));
	}

	function acceptTokensFromSwapper(address token, uint256 amount) internal virtual {
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
			token = lendingPool;
		}

		(bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
		require(success && data.length >= 32);
		total += abi.decode(data, (uint256));
		return total;
	}

	function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) external override lock onlyOwner returns (uint128 amount0, uint128 amount1) {
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
		uint256 ratio = 0x100000000000000000000000000000000 + poolPolarity ? (uint256(amount0) << 128) / tmp.reserve0 : (uint256(amount1) << 128) / tmp.reserve1;
		curveLimit = Math.mulDiv(curveLimit, ratio, 0x100000000000000000000000000000000);

		require(IERC20(token0).transferFrom(msg.sender, amount0));
		require(IERC20(token1).transferFrom(msg.sender, amount1));
		tmp.reserve0 += amount0;
		tmp.reserve1 += amount1;
		reserves = tmp;

		return (amount0, amount1);
	}
}
