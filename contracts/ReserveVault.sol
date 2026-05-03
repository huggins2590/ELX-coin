// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IELXTokenForReserve {
    function getSellVolumeLastHour() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function sellPressureThresholdBps() external view returns (uint256);
    function WBNB() external view returns (address);
}

contract ReserveVault {
    uint256 public totalBNBReceived;
    uint256 public totalBNBDistributed;
    uint256 public totalBNBBuyback;

    address public elxToken;
    IUniswapV2Router02 public pancakeRouter;
    address public WBNB;
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    uint256 public constant MIN_RESERVE_BALANCE = 0.01 ether;

    // Buyback execution limits (the "2-4-24" guard)
    uint256 public lastBuybackTime;
    uint256 public buybacksToday;
    uint256 public dayStartTime;
    uint256 public constant MAX_BUYBACKS_PER_DAY = 2;
    uint256 public constant BUYBACK_COOLDOWN = 4 hours;
    uint256 public constant DAY_DURATION = 24 hours;

    uint256 public executionPercent = 5;
    uint256 public minBuybackAmount = 0.05 ether;
    uint16 public slippageBps = 1000; // 10% slippage
    bool private executing;

    event BNBReceived(uint256 amount);
    event BuybackExecuted(uint256 bnbSpent, uint256 timestamp);
    event BuybackFailed(uint256 bnbSpent);

    modifier lockExecution() {
        executing = true;
        _;
        executing = false;
    }

    constructor(address _elxToken, address _routerAddress) {
        elxToken = _elxToken;
        pancakeRouter = IUniswapV2Router02(_routerAddress);
        WBNB = IELXTokenForReserve(_elxToken).WBNB();
        dayStartTime = block.timestamp;
    }

    receive() external payable {
        totalBNBReceived += msg.value;
        emit BNBReceived(msg.value);
    }

    function shouldExecuteBuyback() public view returns (bool) {
        // Don't re-enter
        if (executing) return false;

        // Check 24h window reset
        uint256 todayBuybacks = buybacksToday;
        if (block.timestamp >= dayStartTime + DAY_DURATION) {
            todayBuybacks = 0; // Would reset on execution
        }

        // Max 2 per day
        if (todayBuybacks >= MAX_BUYBACKS_PER_DAY) return false;

        // 4-hour cooldown
        if (lastBuybackTime != 0 && block.timestamp < lastBuybackTime + BUYBACK_COOLDOWN) return false;

        uint256 available = _getAvailableBNB();
        if (available == 0) return false;

        // Check sell pressure from ELXToken
        if (elxToken == address(0)) return false;
        try IELXTokenForReserve(elxToken).getSellVolumeLastHour() returns (uint256 sellVolume) {
            uint256 supply = IELXTokenForReserve(elxToken).totalSupply();
            uint256 thresholdBps = IELXTokenForReserve(elxToken).sellPressureThresholdBps();
            if (supply == 0 || thresholdBps == 0) return false;

            uint256 threshold = (supply * thresholdBps) / 10000;
            return sellVolume >= threshold;
        } catch {
            return false;
        }
    }

    function executeBuyback() external lockExecution {
        require(msg.sender == elxToken, "Only ELX token");

        // Reset 24h window if needed
        if (block.timestamp >= dayStartTime + DAY_DURATION) {
            dayStartTime = block.timestamp;
            buybacksToday = 0;
        }

        // Re-check guards (in case state changed)
        require(buybacksToday < MAX_BUYBACKS_PER_DAY, "Max buybacks reached");
        require(
            lastBuybackTime == 0 || block.timestamp >= lastBuybackTime + BUYBACK_COOLDOWN,
            "Cooldown active"
        );

        uint256 available = _getAvailableBNB();
        uint256 spendAmount = (available * executionPercent) / 100;
        
        require(spendAmount >= minBuybackAmount, "Min amount check failed");

        uint256 prevLastBuybackTime = lastBuybackTime;
        lastBuybackTime = block.timestamp;
        buybacksToday++;
        totalBNBBuyback += spendAmount;
        totalBNBDistributed += spendAmount;

        // Execute BNB → ELX swap, tokens go to BURN_ADDRESS
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = elxToken;

        // Calculate minOut based on 10% slippage
        uint256 minOut = 0;
        try pancakeRouter.getAmountsOut(spendAmount, path) returns (uint256[] memory amounts) {
            minOut = (amounts[1] * (10000 - slippageBps)) / 10000;
        } catch {}

        try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: spendAmount}(
            minOut,
            path,
            BURN_ADDRESS,
            block.timestamp
        ) {
            emit BuybackExecuted(spendAmount, block.timestamp);
        } catch {
            lastBuybackTime = prevLastBuybackTime;
            buybacksToday = buybacksToday > 0 ? buybacksToday - 1 : 0;
            totalBNBBuyback -= spendAmount;
            totalBNBDistributed -= spendAmount;
            emit BuybackFailed(spendAmount);
        }
    }

    function _getAvailableBNB() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance <= MIN_RESERVE_BALANCE) return 0;
        return balance - MIN_RESERVE_BALANCE;
    }

    // View functions
    function currentBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function availableForBuyback() external view returns (uint256) {
        return _getAvailableBNB();
    }

    function getTotals() external view returns (uint256 received, uint256 distributed, uint256 buyback) {
        return (totalBNBReceived, totalBNBDistributed, totalBNBBuyback);
    }

    function getGuardStatus() external view returns (
        uint256 _lastBuybackTime,
        uint256 _buybacksToday,
        uint256 _dayStartTime,
        bool _canExecute
    ) {
        uint256 todayCount = buybacksToday;
        if (block.timestamp >= dayStartTime + DAY_DURATION) {
            todayCount = 0;
        }
        return (lastBuybackTime, todayCount, dayStartTime, shouldExecuteBuyback());
    }
}
