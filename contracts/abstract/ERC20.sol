// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../interfaces/IERC20.sol";


abstract contract BasicERC20 is IERC20 {

	address constant DEAD = 0x000000000000000000000000000000000000dEaD;
	address constant ZERO = 0x0000000000000000000000000000000000000000;

	string _name;
	string _symbol;
	uint8 immutable _decimals;

	uint256 _totalSupply = 0;

	mapping(address => uint256) _balances;
	mapping(address => mapping(address => uint256)) _allowances;

	constructor(string memory initName, string memory initSymbol, uint8 initDecimals) {
		_name = initName;
		_symbol = initSymbol;
		_decimals = initDecimals;
	}


	function totalSupply() external view override returns (uint256) {
		return _totalSupply;
	}

	function decimals() external view returns (uint8) {
		return _decimals;
	}

	function symbol() external view returns (string memory) {
		return _symbol;
	}

	function name() external view returns (string memory) {
		return _name;
	}

	function balanceOf(address account) public view override returns (uint256) {
		return _balances[account];
	}

	function transfer(address to, uint tokens) public virtual override returns (bool success) {
		require(to != address(0), "Invalid address");
		require(tokens <= _balances[msg.sender], "Insufficient funds");

		_transfer(to, msg.sender, tokens);

		return true;
	}

	function approve(address spender, uint tokens) public virtual override returns (bool success) {
		_allowances[msg.sender][spender] = tokens;
		emit Approval(msg.sender, spender, tokens);

		return true;
	}

	function allowance(address holder, address spender) external view override returns (uint256) {
		return _allowances[holder][spender];
	}

	function transferFrom(address from, address to, uint tokens) public virtual override returns (bool success) {
		require(to != address(0x0), "Invalid address");
		require(tokens <= _allowances[from][msg.sender], "Allowance exceeded");

		unchecked {
			_allowances[from][msg.sender] = _allowances[from][msg.sender] - tokens;
		}

		_transfer(to, from, tokens);

		return true;
	}

	function _transfer(address to, address from, uint256 tokens) internal {
		require(_balances[from] >= tokens, "Insufficient funds");

		_balances[from] -= tokens;

		if (to != address(0x0))
			_balances[to] += tokens;
		else
			_totalSupply -= tokens;

		emit Transfer(from, to, uint(tokens));
	}

	function _mint(address to, uint256 amount) internal {
		_balances[to] += amount;
		_totalSupply += amount;

		emit Transfer(address(0), to, amount);
	}

	function _burn(address from, uint256 amount) internal {
		unchecked {
			uint256 previousBalance = _balances[from];
			require(previousBalance >= amount);
			_balances[from] = previousBalance - amount;
			_totalSupply -= amount;
		}

		emit Transfer(from, address(0), amount);
	}

	function approveMaxAmount(address spender) external returns (bool) {
		return approve(spender, type(uint256).max);
	}

	function getCirculatingSupply() public view returns (uint256) {
		return _totalSupply - balanceOf(DEAD);
	}
}
