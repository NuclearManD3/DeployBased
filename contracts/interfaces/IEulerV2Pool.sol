// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


interface IEulerV2Pool {
	function deposit(uint256 assets, address receiver) external returns (uint256 shares);
	function mint(uint256 shares, address receiver) external returns (uint256 assets);
	function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
	function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
