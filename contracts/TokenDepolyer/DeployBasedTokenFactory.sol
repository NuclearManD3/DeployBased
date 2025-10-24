// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;


import "../abstract/ownable.sol";
import "../interfaces/IDeployBasedPoolFactory.sol";
import "../interfaces/IDeployBasedTokenFactory.sol";

import "./UniversalSafeERC20.sol";


contract DeployBasedTokenFactory is IDeployBasedTokenFactory, Ownable {
	// Proxy exposes these, so we can keep them internal
	uint256 internal totalTokens;
	mapping(uint256 => address) internal tokens;
	address internal poolFactory;

	event PoolFactoryUpdated(address indexed _old, address indexed _new);

	function setPoolFactory(address _new) external onlyOwner {
		emit PoolFactoryUpdated(poolFactory, _new);
		poolFactory = _new;
	}

	function launchToken(string memory name, string memory symbol, uint8 decimals, address reserve, uint24 fee, uint96 priceMultiple, uint160 sqrtPriceX96, uint96 curveLimit, uint128 reserveOffset, uint128 amount)
		external returns (address token, address pool)
	{
		address _factory = poolFactory;
		token = address(new UniversalSafeERC20(name, symbol, decimals, address(this), amount));
		IERC20(token).approve(_factory, amount);
		pool = IDeployBasedPoolFactory(_factory).createPool(reserve, token, fee, priceMultiple, sqrtPriceX96, curveLimit, reserveOffset, amount, msg.sender);
		Ownable(token).transferOwnership(msg.sender);

		unchecked {
			uint256 counter = totalTokens;
			tokens[counter] = token;
			totalTokens = counter + 1;
		}

		emit TokenCreated(token, decimals, name, symbol);
	}
}
