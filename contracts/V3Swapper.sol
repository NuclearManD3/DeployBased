// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


import "./interfaces/IERC20.sol";


interface IUniswapV3Pool {
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256 amount0, int256 amount1);
	function token0() external view returns (address);
	function token1() external view returns (address);
}


// Quick swapping contract to get us off the ground
contract SwapperV3 {
	address transient swapper;
	address transient expectedPoolAddress;
	uint256 transient limits;

	function uniswapV3SwapCallback(
		int256 amount0Delta,
		int256 amount1Delta,
		bytes calldata data
	) external {
		require(expectedPoolAddress == msg.sender, "Unexpected caller");

		uint256 limitsTmp = limits;
		uint256 minimum = limitsTmp & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
		uint256 maximum = limitsTmp >> 128;

		uint256 amount = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
		uint256 amountOut = uint256(amount0Delta < 0 ? -amount0Delta : -amount1Delta);
		require(amount <= maximum);
		require(amountOut >= minimum);

		IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
		address srcToken = amount0Delta > 0 ? pool.token0() : pool.token1();
		IERC20(srcToken).transferFrom(swapper, msg.sender, amount);
		swapper = address(0);
		expectedPoolAddress = address(0);
	}

	function swapV3ExactIn(address pool, bool zeroForOne, uint256 amountIn, uint128 minimum) external {
		swapper = msg.sender;
		expectedPoolAddress = pool;
		limits = uint256(minimum) | (amountIn << 128);
		uint160 ratio = zeroForOne ? 0x1000276FF : 0x00fffd8963efd1fc6a506488495d951d5263988d00;
		IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, int256(amountIn), ratio, "");
	}

	function swapV3ExactOut(address pool, bool zeroForOne, uint256 amountOut, uint128 maximum) external {
		swapper = msg.sender;
		expectedPoolAddress = pool;
		limits = amountOut | (uint256(maximum) << 128);
		uint160 ratio = zeroForOne ? 0x1000276FF : 0x00fffd8963efd1fc6a506488495d951d5263988d00;
		IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, -int256(amountOut), ratio, "");
	}
}