// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";

import "../abstract/ERC20.sol";

import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/IDeployBasedPoolFactory.sol";
import "../interfaces/IERC20.sol";

import "../libs/Math.sol";
import "../libs/UniswapV3Lib.sol";


struct LaunchPoolInitParams {
	/// Launched token will be withdrawn from this address
	address liquiditySource;

	/// Multiplier M in `T = Mx + y`, where x is reserve tokens and y is launch tokens
	/// Note the actual equation used is `(T << 120) = M * x + (y << 24)
	uint96 multiplier;

	/// Starting price
	uint160 sqrtPriceX96;

	/// Constant sum T in `T = Mx + y`, where x is reserve tokens and y is launch tokens
	/// Note the actual equation used is `(T << 120) = M * x + (y << 24)
	uint96 sum;

	/// Amount of tokens to add to the pool
	uint128 amount;

	/// Amount of reserve tokens needed to switch to xy = k mode
	uint128 curveLimit;
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
///  dy = (dx^2) / (dx*P0 + M * ((x0 + dx)**2 - x0**2))
///
/// Most of this code is from Uniswap, and has been modified to support a custom use case.
/// For now I have removed support for concentrated liquidity, since it adds a lot of
/// complexity and I am trying to build a prototype quickly.


contract DeployBasedLaunchPool is IUniswapV3Pool, BasicERC20 {
	using Oracle for Oracle.Observation[65535];

	/// @inheritdoc IUniswapV3PoolImmutables
	address public immutable override factory;
	/// @inheritdoc IUniswapV3PoolImmutables
	address public immutable override token0;
	/// @inheritdoc IUniswapV3PoolImmutables
	address public immutable override token1;
	/// @inheritdoc IUniswapV3PoolImmutables
	uint24 public immutable override fee;

	address public immutable reserve;
	address public immutable launch;
	address public immutable lendingPool;
	/// @dev `poolPolarity = (reserve == token0)`  This is true if `zeroForOne` indicates purchase of `launch`
	bool internal immutable poolPolarity;

	// CURVE CONFIGURATION
	/// Multiplier M in `T = Mx + y`, where x is reserve tokens and y is launch tokens
	/// Note the actual equation used is `(T << 120) = M * x + (y << 24)
	uint256 internal immutable reserveMultiplier;
	/// Starting price
	uint160 internal immutable startSqrtPriceX96;
	/// Constant sum T in `T = Mx + y`, where x is reserve tokens and y is launch tokens
	/// Note the actual equation used is `curveSum = M * x + (y << 24)`
	/// This is equal to `InitParams.sum << 120`
	uint256 internal immutable curveSum;
	/// Amount of reserve tokens needed to switch to xy = k mode
	uint128 internal immutable curveLimit;

	/// @inheritdoc IUniswapV3PoolImmutables
	int24 public immutable override tickSpacing = 1;

	/// @inheritdoc IUniswapV3PoolImmutables
	uint128 public immutable override maxLiquidityPerTick = type(uint128).max;

	struct Slot0 {
		// the current price
		uint160 sqrtPriceX96;
		// the current tick
		int24 tick;
		// the most-recently updated index of the observations array
		uint16 observationIndex;
		// the current maximum number of observations that are being stored
		uint16 observationCardinality;
		// the next maximum number of observations to store, triggered in observations.write
		uint16 observationCardinalityNext;
		// the current protocol fee as a percentage of the swap fee taken on withdrawal
		// represented as an integer denominator (1/x)%
		uint8 feeProtocol;
		// whether the pool is locked (unused for our purpose, as we use TSTORE/TLOAD instead)
		bool unlocked;
	}
	/// @inheritdoc IUniswapV3PoolState
	Slot0 public override slot0;

	struct Reserves {
		uint128 reserve0;
		uint128 reserve1;
	}
	/// Reserves
	Reserves public reserves;

	/// For fee calculations
	struct FeeGrowth {
		uint256 amount0;
		uint256 amount1;
	}
	mapping(address => FeeGrowth) internal feesLast;
	uint256 internal claimedFees0;
	uint256 internal claimedFees1;

	/// @inheritdoc IUniswapV3PoolState
	function feeGrowthGlobal0X128() public override returns (uint256) {
		return mulDiv(balance(token0) + claimedFees0, 1 << 128, liquidity);
	}

	/// @inheritdoc IUniswapV3PoolState
	function feeGrowthGlobal1X128() public override returns (uint256) {
		return mulDiv(balance(token1) + claimedFees1, 1 << 128, liquidity);
	}

	// accumulated protocol fees in token0/token1 units
	struct ProtocolFees {
		uint128 token0;
		uint128 token1;
	}
	/// @inheritdoc IUniswapV3PoolState
	ProtocolFees public immutable override protocolFees = ProtocolFees(0, 0);

	/// @inheritdoc IUniswapV3PoolState
	uint128 public override liquidity;

	/// @inheritdoc IUniswapV3PoolState
	Oracle.Observation[65535] public override observations;

	/// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
	/// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
	/// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
	modifier lock() {
		assembly {
			if tload(0x6c6f636b) {
				mstore(0, 0x6c6f636b6564)
				revert(26, 6)
			}
			tstore(0x6c6f636b, 1)
		}
		_;
		assembly {
			tstore(0x6c6f636b, 0)
		}
	}

	/// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
	modifier onlyFactoryOwner() {
		require(msg.sender == IUniswapV3Factory(factory).owner());
		_;
	}

	constructor(address _reserve, address _launch, address _lend, uint24 _fee, LaunchPoolInitParams calldata initParams) {
		// Initialize immutables
		(factory, reserve, launch, lendingPool, fee) = (msg.sender, _reserve, _launch, _lend, _fee);
		if (_launch < _reserve)
			(token0, token1, poolPolarity) = (_launch, _reserve, 0);
		else
			(token0, token1, poolPolarity) = (_reserve, _launch, 1);

		// Storage initialization
		int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

		(uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

		slot0 = Slot0({
			sqrtPriceX96: sqrtPriceX96,
			tick: tick,
			observationIndex: 0,
			observationCardinality: cardinality,
			observationCardinalityNext: cardinalityNext,
			feeProtocol: 0,
			unlocked: true
		});

		emit Initialize(sqrtPriceX96, tick);
	}

	/// @inheritdoc IUniswapV3PoolActions
	/// @dev Doesn't do anything since we initialize in constructor
	function initialize() external override {}

	/// @dev Common checks for valid tick inputs.
	function checkTicks(int24 tickLower, int24 tickUpper) private pure {
		//require(tickLower < tickUpper, "TLU");
		//require(tickLower >= TickMath.MIN_TICK, "TLM");
		//require(tickUpper <= TickMath.MAX_TICK, "TUM");
		require(tickLower == TickMath.MIN_TICK && tickUpper == TickMath.MAX_TICK, "Concentration not yet supported");
	}

	/// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
	function _blockTimestamp() internal view virtual returns (uint32) {
		return uint32(block.timestamp); // truncation is desired
	}

	/// @param token the token to get a balance of
	/// @dev Get the pool's balance of a given token
	/// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
	/// check
	/// @dev This function also checks if the token is the reserve token, and adds the balance of
	/// lending pool tokens in this case.
	function balance(address token) private view returns (uint256) {
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

	/// @inheritdoc IUniswapV3PoolDerivedState
	function snapshotCumulativesInside(int24 tickLower, int24 tickUpper) external view override returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside) {
		checkTicks(tickLower, tickUpper);

		int56 tickCumulativeLower;
		int56 tickCumulativeUpper;
		uint160 secondsPerLiquidityOutsideLowerX128;
		uint160 secondsPerLiquidityOutsideUpperX128;
		uint32 secondsOutsideLower;
		uint32 secondsOutsideUpper;

		{
			Tick.Info storage lower = ticks[tickLower];
			Tick.Info storage upper = ticks[tickUpper];
			bool initializedLower;
			(tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
				lower.tickCumulativeOutside,
				lower.secondsPerLiquidityOutsideX128,
				lower.secondsOutside,
				lower.initialized
			);
			require(initializedLower);

			bool initializedUpper;
			(tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
				upper.tickCumulativeOutside,
				upper.secondsPerLiquidityOutsideX128,
				upper.secondsOutside,
				upper.initialized
			);
			require(initializedUpper);
		}

		Slot0 memory _slot0 = slot0;

		if (_slot0.tick < tickLower) {
			return (
				tickCumulativeLower - tickCumulativeUpper,
				secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
				secondsOutsideLower - secondsOutsideUpper
			);
		} else if (_slot0.tick < tickUpper) {
			uint32 time = _blockTimestamp();
			(int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
				time,
				0,
				_slot0.tick,
				_slot0.observationIndex,
				liquidity,
				_slot0.observationCardinality
			);
			return (
				tickCumulative - tickCumulativeLower - tickCumulativeUpper,
				secondsPerLiquidityCumulativeX128 -
					secondsPerLiquidityOutsideLowerX128 -
					secondsPerLiquidityOutsideUpperX128,
				time - secondsOutsideLower - secondsOutsideUpper
			);
		} else {
			return (
				tickCumulativeUpper - tickCumulativeLower,
				secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
				secondsOutsideUpper - secondsOutsideLower
			);
		}
	}

	/// @inheritdoc IUniswapV3PoolDerivedState
	function observe(uint32[] calldata secondsAgos) external view override returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
		return observations.observe(
			_blockTimestamp(),
			secondsAgos,
			slot0.tick,
			slot0.observationIndex,
			liquidity,
			slot0.observationCardinality
		);
	}

	/// @inheritdoc IUniswapV3PoolActions
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external override lock {
		uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
		uint16 observationCardinalityNextNew = observations.grow(
			observationCardinalityNextOld,
			observationCardinalityNext
		);
		slot0.observationCardinalityNext = observationCardinalityNextNew;
		if (observationCardinalityNextOld != observationCardinalityNextNew)
			emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
	}

	function _collect(address who, address recipient) internal returns (uint128 amount0, uint128 amount1) {
		uint256 shares = balanceOf(who);

		if (shares > 0) {
			FeeGrowth memory feeGrowth = feesLast[who];
			uint256 growth0 = feeGrowthGlobal0X128();
			uint256 growth1 = feeGrowthGlobal1X128();
			uint256 tokensOwed0 = Math.mulDiv(growth0 - feeGrowth.amount0, shares, 0x100000000000000000000000000000000);
			uint256 tokensOwed1 = Math.mulDiv(growth1 - feeGrowth.amount1, shares, 0x100000000000000000000000000000000);
			_pay(token0, recipient, tokensOwed0);
			_pay(token1, recipient, tokensOwed1);
			claimedFees0 += tokensOwed0;
			claimedFees1 += tokensOwed1;

			(amount0, amount1) = (uint128(claimedFees0), uint128(claimedFees1));

			emit Collect(who, recipient, TickMath.MIN_TICK, TickMath.MAX_TICK, amount0, amount1);
		} else
			(amount0, amount1) = (0, 0);
	}

	/// @inheritdoc IUniswapV3PoolActions
	function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data) external override lock returns (uint256 amount0, uint256 amount1) {
		require(amount > 0);

		(amount0, amount1) = _liquidityToAmounts(amount);
		liquidity += uint256(amount);

		_collect(msg.sender, msg.sender);
		_mint(recipient, amount);

		uint256 balance0Before;
		uint256 balance1Before;
		if (amount0 > 0) balance0Before = balance(token0);
		if (amount1 > 0) balance1Before = balance(token1);
		IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
		if (amount0 > 0) require(balance0Before + amount0 <= balance0(token0), "M0");
		if (amount1 > 0) require(balance1Before + amount1 <= balance1(token1), "M1");

		_depositReserveTokens();

		emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
	}

	/// @inheritdoc IUniswapV3PoolActions
	function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) external override lock returns (uint128 amount0, uint128 amount1) {
		(amount0, amount1) = _collect(msg.sender);
	}

	/// @inheritdoc IUniswapV3PoolActions
	function burn(int24 tickLower, int24 tickUpper, uint128 amount) external override lock returns (uint256 amount0, uint256 amount1) {
		// Collect fees first
		_collect(msg.sender, msg.sender);

		// Compute payments
		(amount0, amount1) = _liquidityToAmounts(amount);
		_pay(token0, msg.sender, amount0);
		_pay(token1, msg.sender, amount1);

		// Burn liquidity tokens
		_burn(msg.sender, amount);

		emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
	}

	/// @inheritdoc IUniswapV3PoolActions
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external override lock returns (int256 amount0, int256 amount1) {
		require(amountSpecified != 0, "AS");

		Slot0 memory slot0Start = slot0;

		require(
			zeroForOne
				? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
				: sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
			"SPL"
		);

		// Scoping keeps stack short and helps control which variables can be used where
		uint256 amtIn;
		uint256 amtOut;
		bool exactInput = amountSpecified > 0;
		unchecked {
			uint256 absSpecified = uint256(exactInput ? amountSpecified : -amountSpecified);

			// Switch the price into terms of reserve and launch
			if (poolPolarity)
				sqrtPriceLimitX96 = uint160(0x1000000000000000000000000000000000000000000000000 / uint256(sqrtPriceLimitX96));

			uint160 newSqrtPriceX96;
			if (zeroForOne == poolPolarity)
				(newSqrtPriceX96, amtIn, amtOut) = _purchaseLaunch(exactInput, absSpecified, sqrtPriceLimitX96);
			else
				(newSqrtPriceX96, amtIn, amtOut) = _sellLaunch(exactInput, absSpecified, sqrtPriceLimitX96);

			// Switch the price back to terms of token0 and token1
			if (poolPolarity)
				newSqrtPriceX96 = uint160(0x1000000000000000000000000000000000000000000000000 / uint256(newSqrtPriceX96));

			if (exactInput) {
				// Subtract from output for fees, if exact input
				feeAmount = Math.mulDiv(amtOut, fee, 1e6);
				amtOut -= feeAmount;
			}
		}

		// DEV NOTE: We do not update any global fee tracker, as the extra balances on top of reserves count as the fees.

		// update tick and write an oracle entry if the tick changed
		int24 newTick = TickMath.getTickAtSqrtRatio(newSqrtPriceX96);
		if (newTick != slot0Start.tick) {
			(uint16 observationIndex, uint16 observationCardinality) = observations.write(
				slot0Start.observationIndex,
				cache.blockTimestamp,
				slot0Start.tick,
				cache.liquidityStart,
				slot0Start.observationCardinality,
				slot0Start.observationCardinalityNext
			);
			(slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
				newSqrtPriceX96,
				newTick,
				observationIndex,
				observationCardinality
			);
		} else
			// otherwise just update the price
			slot0.sqrtPriceX96 = state.sqrtPriceX96;

		(amount0, amount1) = zeroForOne ? (int256(amtIn), int256(-amtOut)) : (int256(-amtOut), int256(amtIn));

		// do the transfers and collect payment
		(address src, address dst) = zeroForOne ? (token0, token1) : (token1, token0);
		require(ERC20(dst).transfer(recipient, amtIn));
		uint256 balance0Before = IERC20(src).balanceOf(address(this));
		IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
		require(balance0Before.add(uint256(amount0)) <= IERC20(src).balanceOf(address(this)), "IIA");

		if (zeroForOne == poolPolarity)
			_depositReserveTokens();

		emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
	}

	/// @inheritdoc IUniswapV3PoolActions
	function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override lock {
		uint128 _liquidity = liquidity;
		require(_liquidity > 0, "L");

		uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
		uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
		uint256 balance0Before = balance0();
		uint256 balance1Before = balance1();

		if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
		if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

		IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

		uint256 balance0After = balance0();
		uint256 balance1After = balance1();

		require(balance0Before.add(fee0) <= balance0After, "F0");
		require(balance1Before.add(fee1) <= balance1After, "F1");

		// sub is safe because we know balanceAfter is gt balanceBefore by at least fee
		uint256 paid0 = balance0After - balance0Before;
		uint256 paid1 = balance1After - balance1Before;

		if (paid0 > 0) {
			uint8 feeProtocol0 = slot0.feeProtocol % 16;
			uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
			if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
			feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
		}
		if (paid1 > 0) {
			uint8 feeProtocol1 = slot0.feeProtocol >> 4;
			uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
			if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
			feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
		}

		emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
	}
}
