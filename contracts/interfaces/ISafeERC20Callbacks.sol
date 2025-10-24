// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


interface ISafeERC20Callbacks {
    function onTransfer(address from, address to, uint256 amount) external;
    function onTransferFrom(address caller, address from, address to, uint256 amount) external;
}
