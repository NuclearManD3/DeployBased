// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;


import "../abstract/ownable.sol";
import "../interfaces/IERC20.sol";


contract DeployBasedTokenFactoryProxy is Ownable {
    uint256 public totalTokens;
    mapping(uint256 => address) public tokens;
    address public poolFactory;

	function implementation() public view returns (address impl) {
		assembly {
			impl := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
		}
	}

	constructor(address impl, address _poolFactory) {
        poolFactory = _poolFactory;
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

	function claim(address token) external onlyOwner {
		IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
	}

	function setImplementation(address impl) public onlyOwner {
		assembly {
			sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, impl)
		}

		emit ImplementationChanged(impl);
	}

	event ImplementationChanged(address indexed impl);
}
