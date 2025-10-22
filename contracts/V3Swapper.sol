// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


import './IERC20.sol';


interface IUniswapV3Pool {
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256 amount0, int256 amount1);
	function token0() external view returns (address);
	function token1() external view returns (address);
}


contract SwapperV3 {
	address transient swapper;
	address transient expectedPoolAddress;

	function uniswapV3SwapCallback(
		int256 amount0Delta,
		int256 amount1Delta,
		bytes calldata data
	) external {
		require(expectedPoolAddress == msg.sender, "Unexpected caller");

		IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
		address srcToken = amount0Delta > 0 ? pool.token0() : pool.token1();
		uint256 amount = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
		IERC20(srcToken).transferFrom(swapper, msg.sender, amount);
		swapper = address(0);
		expectedPoolAddress = address(0);
	}

	function swapV3ExactIn(address pool, bool zeroForOne, uint256 amountIn) external {
		swapper = msg.sender;
		expectedPoolAddress = pool;
		uint160 ratio = zeroForOne ? 0x1000276FF : 0x00fffd8963efd1fc6a506488495d951d5263988d00;
		IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, int256(amountIn), ratio, "");
	}

	function swapV3ExactOut(address pool, bool zeroForOne, uint256 amountOut) external {
		swapper = msg.sender;
		expectedPoolAddress = pool;
		uint160 ratio = zeroForOne ? 0x1000276FF : 0x00fffd8963efd1fc6a506488495d951d5263988d00;
		IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, -int256(amountOut), ratio, "");
	}
}