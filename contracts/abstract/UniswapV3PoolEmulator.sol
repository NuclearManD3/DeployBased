// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../interfaces/IERC20.sol";
import "../libs/Math.sol";
import "../libs/UniswapV3Lib.sol";


interface IUniswapV3Callback {
	/// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
	/// @dev In the implementation you must pay the pool tokens owed for the swap.
	/// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
	/// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
	/// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
	/// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
	/// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
	/// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
	/// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
	function uniswapV3SwapCallback(
		int256 amount0Delta,
		int256 amount1Delta,
		bytes calldata data
	) external;


	/// @notice Called to `msg.sender` after transferring to the recipient from IUniswapV3Pool#flash.
	/// @dev In the implementation you must repay the pool the tokens sent by flash plus the computed fee amounts.
	/// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
	/// @param fee0 The fee amount in token0 due to the pool by the end of the flash
	/// @param fee1 The fee amount in token1 due to the pool by the end of the flash
	/// @param data Any data passed through by the caller via the IUniswapV3PoolActions#flash call
	function uniswapV3FlashCallback(
		uint256 fee0,
		uint256 fee1,
		bytes calldata data
	) external;
}


// We mimic a Uniswap V3 pool to provide a standard interface for
// other systems to deposit or withdraw.
abstract contract UniswapV3PoolEmulator {
	using Oracle for Oracle.Observation[65535];

	struct Slot0Modified {
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
		uint8 reserved1;
		// whether the pool is locked
		bool reserved2;
	}

	address public immutable factory;
	address public immutable token0;
	address public immutable token1;
	uint24 public fee;

	function feeGrowthGlobal0X128() public virtual view returns (uint256);
	function feeGrowthGlobal1X128() public virtual view returns (uint256);
	function liquidity() public virtual view returns (uint128);

	Slot0Modified public slot0;

	Oracle.Observation[65535] public /*override*/ observations;

	constructor(uint160 sqrtPriceX96, address _factory, address _token0, address _token1, uint24 _fee) {
		if (token0 < token1)
			(factory, token0, token1, fee) = (_factory, _token0, _token1, _fee);
		else
			(factory, token0, token1, fee) = (_factory, _token1, _token0, _fee);

		// Storage initialization
		int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

		(uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

		slot0 = Slot0Modified({
			sqrtPriceX96: sqrtPriceX96,
			tick: tick,
			observationIndex: 0,
			observationCardinality: cardinality,
			observationCardinalityNext: cardinalityNext,
			reserved1: 0,
			reserved2: true
		});

		emit Initialize(sqrtPriceX96, tick);
	}

	/// @dev Doesn't do anything since we initialize in constructor
	function initialize() external /*override*/ {}

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

	function updateSlot0Price(uint256 asset0Amount, uint256 asset1Amount) internal {
		slot0.sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(asset1Amount, 1 << 192, asset0Amount)));
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
	function balance(address token) internal virtual view returns (uint256) {
		(bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
		require(success && data.length >= 32);
		return abi.decode(data, (uint256));
	}

	function snapshotCumulativesInside(int24 tickLower, int24 tickUpper) external view /*override*/ returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside) {
		/*int56 tickCumulativeLower;
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

		Slot0Modified memory _slot0 = slot0;

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
		}*/
		revert("Not implemented");
	}

	function observe(uint32[] calldata secondsAgos) external view /*override*/ returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
		return observations.observe(
			_blockTimestamp(),
			secondsAgos,
			slot0.tick,
			slot0.observationIndex,
			liquidity(),
			slot0.observationCardinality
		);
	}

	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external /*override*/ lock {
		uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
		uint16 observationCardinalityNextNew = observations.grow(
			observationCardinalityNextOld,
			observationCardinalityNext
		);
		slot0.observationCardinalityNext = observationCardinalityNextNew;
		if (observationCardinalityNextOld != observationCardinalityNextNew)
			emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
	}

	function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data) external /*override*/ lock returns (uint256 amount0, uint256 amount1) {
		revert("Not Implemented");
	}

	function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) external /*override*/ lock returns (uint128 amount0, uint128 amount1) {
		revert("Not Implemented");
	}

	function burn(int24 tickLower, int24 tickUpper, uint128 amount) external /*override*/ lock returns (uint256 amount0, uint256 amount1) {
		revert("Not Implemented");
	}

	/**
	*** SWAP LOGIC
	**/

	function computeExpectedTokensOut(address inputToken, uint256 tokensIn, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public virtual view returns (uint256 tokensOut, uint160 newSqrtPriceX96);
	function computeExpectedTokensIn(address inputToken, uint256 tokensOut, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96) public virtual view returns (uint256 tokensIn, uint160 newSqrtPriceX96);
	function payTokensToSwapper(address token, uint256 amount, address recipient) internal virtual;
	function acceptTokensFromSwapper(address token, uint256 amount) internal virtual;
	function computeFlashLoanFee(uint256 amount0, uint256 amount1) public virtual view returns (uint256 fee0, uint256 fee1) {
		return (amount0 / 500, amount1 / 500);
	}

	/// @notice Swap token0 for token1, or token1 for token0
	/// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
	/// @param recipient The address to receive the output of the swap
	/// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
	/// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
	/// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
	/// value after the swap. If one for zero, the price cannot be greater than this value after the swap
	/// @param data Any data to be passed through to the callback
	/// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive
	/// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) lock external returns (int256 amount0, int256 amount1) {
		require(amountSpecified != 0, 'AS');
		require(
			zeroForOne
				? sqrtPriceLimitX96 > 0x1000276a3
				: sqrtPriceLimitX96 < 0x00fffd8963efd1fc6a506488495d951d5263988d26,
			'SPL'
		);

		Slot0Modified memory slot0Start = slot0;
		bool exactInput = amountSpecified > 0;

		uint256 tokensOut;
		uint256 tokensIn;

		// Compute swap rates
		uint160 newSqrtPriceX96;
		if (exactInput) {
			tokensIn = uint256(amountSpecified);
			(tokensOut, newSqrtPriceX96) = computeExpectedTokensOut(zeroForOne ? token0 : token1, tokensIn, slot0Start.sqrtPriceX96, sqrtPriceLimitX96);
			amount0 = zeroForOne ? amountSpecified : -int256(tokensOut);
			amount1 = zeroForOne ? -int256(tokensOut) : amountSpecified;
		} else {
			tokensOut = uint256(-amountSpecified);
			(tokensIn, newSqrtPriceX96) = computeExpectedTokensIn(zeroForOne ? token0 : token1, tokensOut, slot0Start.sqrtPriceX96, sqrtPriceLimitX96);
			amount0 = zeroForOne ? int256(tokensIn) : amountSpecified;
			amount1 = zeroForOne ? amountSpecified : int256(tokensIn);
		}

		// Update price data and write an oracle entry if the tick changed
		int24 newTick = TickMath.getTickAtSqrtRatio(newSqrtPriceX96);
		if (newTick != slot0Start.tick) {
			(uint16 observationIndex, uint16 observationCardinality) = observations.write(
				slot0Start.observationIndex,
				_blockTimestamp(),
				slot0Start.tick,
				liquidity(),
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
			slot0.sqrtPriceX96 = newSqrtPriceX96;

		// Perform the swap
		uint256 balanceBefore = balance(zeroForOne ? token0 : token1);
		payTokensToSwapper(zeroForOne ? token1 : token0, tokensOut, recipient);
		IUniswapV3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
		uint256 balanceAfter = balance(zeroForOne ? token0 : token1);
		require(balanceAfter - balanceBefore >= tokensIn, 'IIA');

		// Accept the received tokens
		acceptTokensFromSwapper(zeroForOne ? token0 : token1, balanceAfter - balanceBefore);

		// Event
		emit Swap(msg.sender, recipient, amount0, amount1, newSqrtPriceX96, liquidity(), newTick);
	}

	/// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
	/// @dev The caller of this method receives a callback in the form of IUniswapV3FlashCallback#uniswapV3FlashCallback
	/// @dev Can be used to donate underlying tokens pro-rata to currently in-range liquidity providers by calling
	/// with 0 amount{0,1} and sending the donation amount(s) from the callback
	/// @param recipient The address which will receive the token0 and token1 amounts
	/// @param amount0 The amount of token0 to send
	/// @param amount1 The amount of token1 to send
	/// @param data Any data to be passed through to the callback
	function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {

		(uint256 fee0, uint256 fee1) = computeFlashLoanFee(amount0, amount1);
		uint256 balance0Before = IERC20(token0).balanceOf(address(this));
		uint256 balance1Before = IERC20(token1).balanceOf(address(this));

		if (amount0 > 0) payTokensToSwapper(token0, amount0, recipient);
		if (amount1 > 0) payTokensToSwapper(token1, amount1, recipient);

		IUniswapV3Callback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

		uint256 balance0After = IERC20(token0).balanceOf(address(this));
		uint256 balance1After = IERC20(token1).balanceOf(address(this));

		require(balance0Before + fee0 <= balance0After, 'F0');
		require(balance1Before + fee1 <= balance1After, 'F1');

		// sub is safe because we know balanceAfter is gt balanceBefore by at least fee
		uint256 paid0 = balance0After - balance0Before;
		uint256 paid1 = balance1After - balance1Before;

		if (paid0 > 0)
			acceptTokensFromSwapper(token0, paid0);
		if (paid1 > 0)
			acceptTokensFromSwapper(token1, paid1);

		emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
	}

	/// @notice Increase the maximum number of price and liquidity observations that this pool will store
	/// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
	/// the input observationCardinalityNext.
	/// @param observationCardinalityNext The desired minimum number of observations for the pool to store
	//function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

	/// @notice Emitted exactly once by a pool when #initialize is first called on the pool
	/// @dev Mint/Burn/Swap cannot be emitted by the pool before Initialize
	/// @param sqrtPriceX96 The initial sqrt price of the pool, as a Q64.96
	/// @param tick The initial tick of the pool, i.e. log base 1.0001 of the starting price of the pool
	event Initialize(uint160 sqrtPriceX96, int24 tick);

	/// @notice Emitted by the pool for any swaps between token0 and token1
	/// @param sender The address that initiated the swap call, and that received the callback
	/// @param recipient The address that received the output of the swap
	/// @param amount0 The delta of the token0 balance of the pool
	/// @param amount1 The delta of the token1 balance of the pool
	/// @param sqrtPriceX96 The sqrt(price) of the pool after the swap, as a Q64.96
	/// @param liquidity The liquidity of the pool after the swap
	/// @param tick The log base 1.0001 of price of the pool after the swap
	event Swap(
		address indexed sender,
		address indexed recipient,
		int256 amount0,
		int256 amount1,
		uint160 sqrtPriceX96,
		uint128 liquidity,
		int24 tick
	);

	/// @notice Emitted by the pool for any flashes of token0/token1
	/// @param sender The address that initiated the swap call, and that received the callback
	/// @param recipient The address that received the tokens from flash
	/// @param amount0 The amount of token0 that was flashed
	/// @param amount1 The amount of token1 that was flashed
	/// @param paid0 The amount of token0 paid for the flash, which can exceed the amount0 plus the fee
	/// @param paid1 The amount of token1 paid for the flash, which can exceed the amount1 plus the fee
	event Flash(
		address indexed sender,
		address indexed recipient,
		uint256 amount0,
		uint256 amount1,
		uint256 paid0,
		uint256 paid1
	);


	/// @notice Emitted by the pool for increases to the number of observations that can be stored
	/// @dev observationCardinalityNext is not the observation cardinality until an observation is written at the index
	/// just before a mint/swap/burn.
	/// @param observationCardinalityNextOld The previous value of the next observation cardinality
	/// @param observationCardinalityNextNew The updated value of the next observation cardinality
	event IncreaseObservationCardinalityNext(
		uint16 observationCardinalityNextOld,
		uint16 observationCardinalityNextNew
	);
}