// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IELXToken is IERC20 {
    function holderSince(address account) external view returns (uint256);
    function resetRewardTimer(address account) external;
    function eligibleHoldersCount() external view returns (uint256);
}

// Vault for holding and distributing ELX rewards to eligible holders
contract RewardsVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IELXToken;
    
    uint256 public totalTokensDistributed; 
    mapping(address => uint256) public userTotalClaimed; 

    IELXToken public immutable elxToken;
    uint256 public constant REWARD_DURATION = 72 hours;

    event TokensReceived(uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(address _elxToken) {
        require(_elxToken != address(0), "Zero address");
        elxToken = IELXToken(_elxToken);
    }

    function currentBalance() public view returns (uint256) {
        return elxToken.balanceOf(address(this));
    }

    function getTotals() external view returns (uint256 received, uint256 distributed) {
        return (totalTokensReceived(), totalTokensDistributed);
    }

    // Work out how many tokens a user can claim right now
    function getClaimableAmount(address user) public view returns (uint256) {
        if (address(elxToken) == address(0)) return 0;
        
        uint256 totalEligible = elxToken.eligibleHoldersCount();
        if (totalEligible == 0) return 0;

        uint256 since = elxToken.holderSince(user);
        if (since == 0) return 0;
        if (block.timestamp < since + REWARD_DURATION) return 0;
        return currentBalance() / totalEligible;
    }

    function claimReward() external nonReentrant {
        require(address(elxToken) != address(0), "Token not set");
        
        uint256 reward = getClaimableAmount(msg.sender);
        require(reward > 0, "Not eligible or zero reward");
        require(currentBalance() >= reward, "Vault empty");

        // Reset the user's holding timer so they have to wait another 72 hours
        elxToken.resetRewardTimer(msg.sender);

        totalTokensDistributed += reward;
        userTotalClaimed[msg.sender] += reward;
        
        elxToken.safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    // Automated view of total tokens ever sent to this vault
    function totalTokensReceived() public view returns (uint256) {
        return currentBalance() + totalTokensDistributed;
    }
}
