// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;


import "../abstract/ownable.sol";
import "../interfaces/IDeployBasedPoolFactory.sol";
import "../Pools/DeployBasedLaunchPoolSimple.sol";


contract DeployBasedPoolFactory is IDeployBasedPoolFactory, Ownable {

	mapping(address => address) public lendingPools;

	constructor() {
		// USDC
		lendingPools[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = 0xb125E6687d4313864e53df431d5425969c15Eb2F;

		// USDS
		lendingPools[0x820C137fa70C8691f0e44Dc420a5e53c168921Dc] = 0x2c776041CCFe903071AF44aa147368a9c8EEA518;

		// WETH
		lendingPools[0x4200000000000000000000000000000000000006] = 0x46e6b214b524310239732D51387075E0e70970bf;
	}

	//
	//  UniswapV3 Emulation Functions
	//

	function feeAmountTickSpacing(uint24 fee) public view returns (int24 spacing) {
		spacing = int24(uint24(fee / 50));
		if (spacing > 200)
			spacing = 200;
		else if (spacing == 0)
			spacing = 1;
	}

	/// @notice Returns the pool address for a given pair of tokens and a fee, or address 0 if it does not exist
	/// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
	/// @param tokenA The contract address of either token0 or token1
	/// @param tokenB The contract address of the other token
	/// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
	/// @return pool The pool address
	function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool) {
		(address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
		bytes32 salt = keccak256(abi.encodePacked(token0, token1, fee, uint8(1)));

		assembly {
			pool := sload(salt)
		}

		// In the future with more protocol versions:
		/*if (pool == address(0)) {
			bytes32 salt = keccak256(abi.encodePacked(token0, token1, fee, uint8(1)));
			pool = this[uint256(salt)];
		}*/
	}

	function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
		// Not implemented because it doesn't have enough config parameters
		revert();
	}

	function createPool(address reserve, address launch, uint24 fee, uint96 priceMultiple, uint160 sqrtPriceX96, uint96 curveLimit, uint128 reserveOffset, uint128 amount)
		external returns (address pool)
	{
		LaunchPoolInitParams memory initParams = LaunchPoolInitParams(
			lendingPools[reserve],
			priceMultiple,
			sqrtPriceX96,
			curveLimit,
			amount,
			reserveOffset
		);
		pool = deploy(reserve, launch, fee, initParams);
		require(IERC20(launch).transferFrom(msg.sender, pool, amount));
	}

	function setOwner(address _owner) external onlyOwner {
		emit OwnerChanged(owner(), _owner);
		_transferOwnership(_owner);
	}

	function owner() public override(IDeployBasedPoolFactory, Ownable) view returns (address) {
		return Ownable.owner();
	}

	function enableFeeAmount(uint24 fee, int24 tickSpacing) external onlyOwner {
	}

	function setLendingPoolFor(address token, address pool) external onlyOwner {
		lendingPools[token] = pool;
	}

	function deploy(address reserve, address launch, uint24 fee, LaunchPoolInitParams memory initParams) internal returns (address pool) {
		(address token0, address token1) = reserve < launch ? (reserve, launch) : (launch, reserve);
		bytes32 salt = keccak256(abi.encodePacked(token0, token1, fee, uint8(1)));
		pool = address(new DeployBasedLaunchPoolSimple{salt: salt}(reserve, launch, fee, initParams));
		assembly {
			sstore(salt, pool)
		}
	}
}