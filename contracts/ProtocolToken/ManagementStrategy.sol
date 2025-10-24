// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;


import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/IAavePool.sol";
import "../interfaces/ICompoundPool.sol";
import "../interfaces/IEulerV2Pool.sol";
import "../interfaces/IERC20.sol";
import "../libs/Math.sol";
import "../abstract/PriceOracle.sol";


abstract contract LendingStrategy is PriceOracle {
	ISwapRouter internal immutable swapRouter = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);

	address internal immutable USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
	address internal immutable USDS = address(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
	address internal immutable WETH = address(0x4200000000000000000000000000000000000006);

	uint256 public numAssetsHeld;
	mapping(uint256 => address) public assetsHeld;
	mapping(address => uint256) addressToAssetIndex;

	function processStrategyChangeCommandSequence(uint calldataStartPtr, address assetUnit) internal returns (uint256 endValue) {

		// We use this to verify that the contraxt doesn't lose funds or make miscalculations
		// by some kind of mistake
		uint256 startValue = getTotalManaged(assetUnit);

		while (calldataStartPtr < msg.data.length) {
			uint8 command;
			address arg1;
			address token;
			uint256 arg3;
			assembly {
				command := shr(248, calldataload(calldataStartPtr))
				calldataStartPtr := add(calldataStartPtr, 1)
				arg1 := shr(96, calldataload(calldataStartPtr))
				calldataStartPtr := add(calldataStartPtr, 20)
				token := shr(96, calldataload(calldataStartPtr))
				calldataStartPtr := add(calldataStartPtr, 20)
				arg3 := calldataload(calldataStartPtr)
				calldataStartPtr := add(calldataStartPtr, 32)
			}

			if (command & 0xF0 == 0x00) {
				// Deposits
				if (command == 0x00)
					supplyToAaveV3(arg1, token, arg3);
				else if (command == 0x01)
					supplyToCompoundV3(arg1, token, arg3);
				else if (command == 0x02)
					supplyToEuler(arg1, token, arg3);
			} else if (command & 0xF0 == 0x10) {
				// Withdraws
				if (command == 0x10)
					withdrawFromAaveV3(arg1, token, arg3);
				else if (command == 0x11)
					withdrawFromCompoundV3(arg1, token, arg3);
				else if (command == 0x12)
					withdrawFromEuler(arg1, arg3);
			} else if (command & 0xF0 == 0x20) {
				// Swaps
				if (command == 0x23) {
					uint256 minOut;
					assembly {
						minOut := calldataload(calldataStartPtr)
						calldataStartPtr := add(calldataStartPtr, 32)
					}
					swapUniswapV3(arg1, token, arg3, minOut);
				} else if (command == 0x2E) {
					findV3PoolFor(arg1, token, arg3);
				} else if (command == 0x2F) {
					addUniswapV3Pool(arg1);
				}
			} else if (command & 0xF0 == 0x80) {
				// Price and asset holdings data
				if (command == 0x80) {
					setFixedPrice(arg1, token, arg3);
				} else if (command == 0x88) {
					addAssetHeld(arg1);
				} else if (command == 0x89) {
					rmAssetHeld(arg3);
				}
			}
		}

		endValue = getTotalManaged(assetUnit);

		require(endValue * 101 > startValue * 100 && endValue * 99 < startValue * 100, "Suspicious change in total holdings");
	}

	function supplyToAaveV3(address pool, address asset, uint256 amount) internal {
		IERC20(asset).approve(pool, amount);
		IAaveV3Pool(pool).supply(asset, amount, address(this), 0);

		address aTokenAddress = IAaveV3Pool(pool).getReserveAToken(asset);
		addAssetHeld(aTokenAddress);
	}

	function withdrawFromAaveV3(address pool, address asset, uint256 amount) internal {
		IAaveV3Pool(pool).withdraw(asset, amount, address(this));
	}

	function supplyToCompoundV3(address pool, address asset, uint256 amount) internal {
		IERC20(asset).approve(pool, amount);
		ICompoundV3Pool(pool).supply(asset, amount);
		addAssetHeld(pool);
	}

	function withdrawFromCompoundV3(address pool, address asset, uint256 amount) internal {
		ICompoundV3Pool(pool).withdraw(asset, amount);
	}

	function supplyToEuler(address pool, address asset, uint256 amount) internal {
		IERC20(asset).approve(pool, amount);
		IEulerV2Pool(pool).deposit(amount, address(this));

		addAssetHeld(pool);
	}

	function withdrawFromEuler(address pool, uint256 amount) internal {
		IEulerV2Pool(pool).withdraw(amount, address(this), address(this));
	}

	function swapUniswapV3(address _pool, address asset, uint256 amountIn, uint256 outMinimum) internal {
		IUniswapV3Pool pool = IUniswapV3Pool(_pool);

		address token0 = pool.token0();
		address assetOut = asset == token0 ? pool.token1() : token0;

		require(assetOut == USDC || assetOut == USDS || assetOut == WETH, "TOKEN WHITELIST");

		ISwapRouter.ExactInputSingleParams memory params =
			ISwapRouter.ExactInputSingleParams({
				tokenIn: asset,
				tokenOut: assetOut,
				fee: pool.fee(),
				recipient: address(this),
				deadline: block.timestamp,
				amountIn: amountIn,
				amountOutMinimum: outMinimum,
				sqrtPriceLimitX96: 0
			});

		IERC20(asset).approve(address(swapRouter), amountIn);
		swapRouter.exactInputSingle(params);

		addAssetHeld(assetOut);
	}

	function addAssetHeld(address asset) internal {
		if (addressToAssetIndex[asset] == 0) {
			uint256 nextIndex = numAssetsHeld;
			addressToAssetIndex[asset] = (nextIndex << 1) | 1;
			assetsHeld[nextIndex] = asset;

			numAssetsHeld = nextIndex + 1;
		}
	}

	function rmAssetHeld(uint256 index) internal {
		uint256 nextIndex = numAssetsHeld - 1;
		address assetAddress = assetsHeld[index];

		if (index < nextIndex) {
			// Reorder asset list
			addressToAssetIndex[assetsHeld[nextIndex]] = (index << 1) | 1;
			assetsHeld[index] = assetsHeld[nextIndex];
		} else if (index > nextIndex)
			revert("No such index");

		addressToAssetIndex[assetAddress] = 0;
		numAssetsHeld = nextIndex;
	}

	function getTotalManaged(address assetUnit) public view returns (uint256 amount) {
		amount = 0;

		unchecked {
			uint256 count = numAssetsHeld;
			for (uint256 i = 0; i < count; i++) {
				address asset = assetsHeld[i];
				uint256 balance = IERC20(asset).balanceOf(address(this));
				amount += convertUsingTwap(asset, assetUnit, 2 minutes, balance);
			}
		}
	}
}
