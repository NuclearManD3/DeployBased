// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../abstract/UniswapV3PoolEmulator.sol";
import "../abstract/ownable.sol";
import "./ManagementStrategy.sol";
import "../abstract/ERC20.sol";
import "../libs/Math.sol";


/*
 *		deploy();  // Based
 *
 *  Instrument to compensate liquidity providers
 *  for providing liquidity on new tokens
 *
 *  Designed to be anti-inflationary via various means.
 *
*/


contract DeployBasedProtocolToken is BasicERC20, Ownable, ManagementStrategy, UniswapV3PoolEmulator {
	address internal immutable USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
	address internal immutable USDS = address(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
	address internal immutable WETH = address(0x4200000000000000000000000000000000000006);

	constructor(address _factory, uint24 _fee)
		BasicERC20("Deploy", "DPLY", 6)
		UniswapV3PoolEmulator(1 << 96, 0, _factory, address(this), USDC, _fee) {
	}


	// ADMINISTRATION

	fallback() external onlyOwner {
		uint256 aum = processStrategyChangeCommandSequence(0, USDC);

		// Recompute prices
		if (token0 == address(this))
			updateSlot0Price(_totalSupply, aum);
		else
			updateSlot0Price(aum, _totalSupply);
	}

	function setFee(uint24 _fee) external onlyOwner {
		fee = _fee;
	}

	event AssetInitialization(address indexed underlier, address indexed recipient, uint256 investment, uint256 startingSupply);

	function initialize(uint256 initialAmount, uint256 startingSupply, address recipient) external onlyOwner {
		require(_totalSupply == 0, "Already initialized");

		IERC20(USDC).transferFrom(msg.sender, address(this), initialAmount);
		_mint(recipient, startingSupply);

		if (token0 == address(this))
			updateSlot0Price(startingSupply, initialAmount);
		else
			updateSlot0Price(initialAmount, startingSupply);

		emit AssetInitialization(USDC, recipient, initialAmount, startingSupply);
	}

	// EXCHANGE FUNCTIONS

	function computeExpectedTokensOut(address inputToken, uint256 tokensIn, uint160, uint160) public override view returns (uint256 tokensOut) {
		uint256 aum = getTotalManaged(USDC);
		uint256 feeMultiplier = inputToken == address(this) && msg.sender != owner() ? 1e6 - fee : 1e6;

		if (inputToken == address(this))
			return Math.mulDiv(aum, tokensIn * feeMultiplier, _totalSupply) / 1e6;
		else if (inputToken == USDC)
			return Math.mulDiv(_totalSupply, tokensIn * feeMultiplier, aum) / 1e6;
		else
			revert("Token not recognized");
	}

	function computeExpectedTokensIn(address inputToken, uint256 tokensOut, uint160, uint160) public override view returns (uint256 tokensIn) {
		uint256 aum = getTotalManaged(USDC);
		uint256 feeMultiplier = inputToken == address(this) && msg.sender != owner() ? 1e12 / (1e6 + fee) : 1e6;

		if (inputToken == address(this))
			return Math.mulDiv(_totalSupply, tokensOut * feeMultiplier, aum) / 1e6;
		else if (inputToken == USDC)
			return Math.mulDiv(aum, tokensOut * feeMultiplier, _totalSupply) / 1e6;
		else
			revert("Token not recognized");
	}

	function payTokensToSwapper(address token, uint256 amount, address recipient) internal override {
		if (token == address(this)) {
			_mint(recipient, amount);
		} else
			IERC20(token).transfer(recipient, amount);
	}

	function acceptTokensFromSwapper(address token, uint256 amount) internal override {
		if (token == address(this)) {
			uint256 feeAmount = (amount * fee) / 1e6;
			_burn(address(this), amount - feeAmount);
			_transfer(factory, address(this), feeAmount);
		}
	}
}
