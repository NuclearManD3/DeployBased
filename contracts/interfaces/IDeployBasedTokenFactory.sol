// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


interface IDeployBasedTokenFactory {
	event TokenCreated(address indexed token, uint8 decimals, string name, string symbol);

	function totalTokens() external view returns (uint256);
	function tokens(uint256 index) external view returns (address);
	function poolFactory() external view returns (address);

	function launchToken(string memory name, string memory symbol, uint8 decimals, address reserve, uint24 fee, uint96 priceMultiple, uint160 sqrtPriceX96, uint96 curveLimit, uint128 reserveOffset, uint128 amount)
		external returns (address token, address pool);
}
