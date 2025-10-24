// SPDX-License-Identifier: BUSL 1.1
pragma solidity ^0.8.24;

import "../abstract/ownable.sol";
import "../abstract/ERC20.sol";
import "../interfaces/ISafeERC20Callbacks.sol";


/*
 *		deploy();  // Based
 *
 *  A universal ERC20 implementation that is safe to use and
 *  extensible.
 *
 *  Prevents extension code from pausing or freezing assets,
 *  or inflating supply.
 *
*/


contract UniversalSafeERC20 is BasicERC20, Ownable, ISafeERC20Callbacks {
	address public immutable factory;
	address public implementation;

	constructor(string memory name, string memory symbol, uint8 decimals, address _factory, uint256 totalSupply)
		BasicERC20(name, symbol, decimals)
	{
		factory = _factory;
		implementation = address(0);
		_mint(msg.sender, totalSupply);
	}

	/*
	**   Extensibility delegation logic
	*/

	event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);

	function setImplementation(address newImplementation) external onlyOwner {
		emit ImplementationUpdated(implementation, newImplementation);
		implementation = newImplementation;
	}

	modifier onlyImplementation() {
		require(msg.sender == implementation);
		_;
	}

	fallback() external payable {
		address impl = implementation;
		if (msg.sender == impl || impl == address(0))
			return;
		assembly {
            tstore(0, caller())
			calldatacopy(0, 0, calldatasize())
			let result := call(gas(), impl, callvalue(), 0, calldatasize(), 0, 0)
			returndatacopy(0, 0, returndatasize())
			switch result
			case 0 {
				revert(0, returndatasize())
			}
			default {
                tstore(0, 0)
				return(0, returndatasize())
			}
		}
	}

	/*
	**   Implementation/Extensibility calls
	*/

    function originalSender() external returns (address sender) {
        assembly {
            sender := tload(0)
        }
    }

	function implBurn(uint256 tokens) external onlyImplementation {
		_burn(address(this), tokens);
	}

	function implBurnOwn(uint256 tokens) external onlyImplementation {
		_burn(msg.sender, tokens);
	}

	function implTransfer(address dst, uint256 tokens) external onlyImplementation {
		_transfer(dst, address(this), tokens);
	}

	function implTransferFrom(address src, address dst, uint256 tokens) external onlyImplementation {
		uint256 allowance = _allowances[src][address(this)];
		require(tokens <= allowance, "Allowance exceeded");

		unchecked {
			_allowances[src][address(this)] = allowance - tokens;
		}

		_transfer(dst, src, tokens);
	}

	function implApprove(address dst, uint256 allowance) external onlyImplementation {
		_allowances[address(this)][dst] = allowance;
        emit Approval(address(this), dst, allowance);
	}

	function implTransferToken(address token, address dst, uint256 amount) external onlyImplementation {
		require(IERC20(token).transfer(dst, amount));
	}

	function implTransferFromToken(address token, address src, address dst, uint256 amount) external onlyImplementation {
		require(IERC20(token).transferFrom(src, dst, amount));
	}

	function implApproveToken(address token, address dst, uint256 allowance) external onlyImplementation {
		IERC20(token).approve(dst, allowance);
	}

	function implSendEther(address payable dst, uint256 amount) external onlyImplementation {
		dst.transfer(amount);
	}

	function implCall(address payable dst, bytes calldata dataIn) external payable onlyImplementation returns (bool success, bytes memory dataOut) {
		return dst.call{value: msg.value}(dataIn);
	}


	/*
	**  CALLBACK MECHANISMS
	*/

	// These ensure that the implementation cannot freeze funds simply by reverting in the callback.
	// Using all the tx gas also doesn't work for this purpose.

	function transfer(address to, uint tokens) public virtual override returns (bool success) {
		success = BasicERC20.transfer(to, tokens);
		address impl = implementation;
		if (impl != address(0))
			try ISafeERC20Callbacks(impl).onTransfer{gas: gasleft() / 2}(msg.sender, to, tokens) {}
			catch {}
	}

	function transferFrom(address from, address to, uint tokens) public virtual override returns (bool success) {
		success = BasicERC20.transferFrom(from, to, tokens);
		address impl = implementation;
		if (impl != address(0))
			try ISafeERC20Callbacks(impl).onTransferFrom{gas: gasleft() / 2}(msg.sender, from, to, tokens) {}
			catch {}
	}

	// We also must implement the callbacks here, so that hackers cannot make this contract forward false callbacks to the implementation.
	function onTransfer(address, address, uint256) external override { revert(); }
	function onTransferFrom(address, address, address, uint256) external override { revert(); }
}
