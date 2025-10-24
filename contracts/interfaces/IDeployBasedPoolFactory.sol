// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


/// @title The interface for the Uniswap V3 Factory
/// @notice The Uniswap V3 Factory facilitates creation of Uniswap V3 pools and control over the protocol fees
interface IDeployBasedPoolFactory {
	/// @notice Emitted when a pool is created
	/// @param token0 The first token of the pool by address sort order
	/// @param token1 The second token of the pool by address sort order
	/// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
	/// @param initToken0 the amount of token0 deposited to initialize the pool
	/// @param initToken1 the amount of token1 deposited to initialize the pool
	/// @param saleToken the token held when the price is at the price limit
	/// @param sqrtPriceX96Limit the highest/lowest price the pool can reach, depending on token0/token1 order
	/// @param pool The address of the created pool
	event PoolCreated(
		address indexed token0,
		address indexed token1,
		uint24 indexed fee,
		uint256 initToken0,
		uint256 initToken1,
		address saleToken,
		uint160 sqrtPriceX96Limit,
		address pool
	);

	event OwnerChanged(address indexed oldOwner, address indexed newOwner);

	/// @notice Returns the current owner of the factory
	/// @dev Can be changed by the current owner via setOwner
	/// @return The address of the factory owner
	function owner() external view returns (address);

	/// @notice Returns the tick spacing for a given fee amount, if enabled, or 0 if not enabled
	/// @dev A fee amount can never be removed, so this value should be hard coded or cached in the calling context
	/// @param fee The enabled fee, denominated in hundredths of a bip. Returns 0 in case of unenabled fee
	/// @return The tick spacing
	function feeAmountTickSpacing(uint24 fee) external view returns (int24);

	function createPool(address reserve, address launch, uint24 fee, uint96 priceMultiple, uint160 sqrtPriceX96, uint96 curveLimit, uint128 reserveOffset, uint128 amount, address newOwner)
		external returns (address pool);
}