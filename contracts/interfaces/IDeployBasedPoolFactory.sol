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

	/// @notice Returns the pool address for a given pair of tokens and a fee, or address 0 if it does not exist
	/// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
	/// @param tokenA The contract address of either token0 or token1
	/// @param tokenB The contract address of the other token
	/// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
	/// @return pool The pool address
	function getPool(
		address tokenA,
		address tokenB,
		uint24 fee
	) external view returns (address pool);

	/// @notice Creates a pool for the given two tokens and fee
	/// @param tokenA One of the two tokens in the desired pool
	/// @param tokenB The other of the two tokens in the desired pool
	/// @param fee The desired fee for the pool
	/// @dev tokenA and tokenB may be passed in either order: token0/token1 or token1/token0. tickSpacing is retrieved
	/// from the fee. The call will revert if the pool already exists, the fee is invalid, or the token arguments
	/// are invalid.
	/// @return pool The address of the newly created pool
	function createPool(
		address tokenA,
		address tokenB,
		uint24 fee
	) external returns (address pool);
}