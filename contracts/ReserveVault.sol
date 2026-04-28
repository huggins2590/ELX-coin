// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ReserveVault
 * @dev Simple contract to receive and track BNB sent from token tax (0.3% reserve)
 */
contract ReserveVault is Ownable {
    uint256 public totalBNBReceived; // cumulative BNB received
    uint256 public totalBNBDistributed; // cumulative BNB distributed
    address public elxToken;

    event BNBReceived(uint256 amount);
    event BNBWithdrawn(address indexed to, uint256 amount);

    constructor(address _elxToken) {
        elxToken = _elxToken;
    }

    receive() external payable {
        totalBNBReceived += msg.value;
        emit BNBReceived(msg.value);
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        totalBNBDistributed += amount;
        to.transfer(amount);
        emit BNBWithdrawn(to, amount);
    }

    function currentBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getTotals() external view returns (uint256 received, uint256 distributed) {
        return (totalBNBReceived, totalBNBDistributed);
    }
}
