// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;


import "../abstract/ownable.sol";
import "../interfaces/IERC20.sol";


contract DeployBasedPoolFactoryProxy is Ownable {

	mapping(address => address) public lendingPools;

	function implementation() public view returns (address impl) {
		assembly {
			impl := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
		}
	}

	constructor(address impl) {
		// USDC
		lendingPools[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = 0xb125E6687d4313864e53df431d5425969c15Eb2F;

		// USDS
		lendingPools[0x820C137fa70C8691f0e44Dc420a5e53c168921Dc] = 0x2c776041CCFe903071AF44aa147368a9c8EEA518;

		// WETH
		lendingPools[0x4200000000000000000000000000000000000006] = 0x46e6b214b524310239732D51387075E0e70970bf;

		assembly {
			sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, impl)
		}

		emit ImplementationChanged(impl);
	}

	fallback() external payable {
		assembly {
			calldatacopy(0, 0, calldatasize())
			let result := delegatecall(gas(), sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc), 0, calldatasize(), 0, 0)
			returndatacopy(0, 0, returndatasize())
			switch result
			case 0 {
				revert(0, returndatasize())
			}
			default {
				return(0, returndatasize())
			}
		}
	}

	function setLendingPoolFor(address token, address pool) external onlyOwner {
		lendingPools[token] = pool;
	}

	function claim(address token) external onlyOwner {
		IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
	}

	function setOwner(address _owner) external onlyOwner {
		emit OwnerChanged(owner(), _owner);
		_transferOwnership(_owner);
	}

	function setImplementation(address impl) public onlyOwner {
		assembly {
			sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, impl)
		}

		emit ImplementationChanged(impl);
	}

	event ImplementationChanged(address indexed impl);
	event OwnerChanged(address indexed oldOwner, address indexed newOwner);
}
