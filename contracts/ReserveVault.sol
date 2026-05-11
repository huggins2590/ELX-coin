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
    function SELL_PRESSURE_THRESHOLD_BPS() external view returns (uint256);
    function WBNB() external view returns (address);
}

contract ReserveVault {
    uint256 public totalBNBReceived;
    uint256 public totalBNBDistributed;
    uint256 public totalBNBBuyback;

    address public immutable elxToken;
    IUniswapV2Router02 public immutable pancakeRouter;
    address public immutable WBNB;
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    uint256 public constant MIN_RESERVE_BALANCE = 0.01 ether;

    // Buyback execution limits (the "2-4-24" guard)
    uint256 public lastBuybackTime;
    uint256 public buybacksToday;
    uint256 public dayStartTime;
    uint256 public constant MAX_BUYBACKS_PER_DAY = 2;
    uint256 public constant BUYBACK_COOLDOWN = 4 hours;
    uint256 public constant DAY_DURATION = 24 hours;

    uint256 public constant executionPercent = 5;
    uint256 public constant minBuybackAmount = 0.05 ether;
    uint16 public constant slippageBps = 1000; // 10% slippage
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
        require(_elxToken != address(0), "Zero address");
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
            uint256 thresholdBps = IELXTokenForReserve(elxToken).SELL_PRESSURE_THRESHOLD_BPS();
            if (supply == 0 || thresholdBps == 0) return false;

            uint256 threshold = (supply * thresholdBps) / 10000;
            if (sellVolume < threshold) return false;

            // Ensure we have at least the minimum amount to spend
            available = _getAvailableBNB();
            return available >= minBuybackAmount;
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
        
        // If the percentage is too low, use the minimum allowed amount if available
        if (spendAmount < minBuybackAmount && available >= minBuybackAmount) {
            spendAmount = minBuybackAmount;
        }
        
        // Safety: Never spend the MIN_RESERVE_BALANCE
        require(available >= spendAmount + MIN_RESERVE_BALANCE, "Insufficient reserve floor");
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
        return address(this).balance;
    }

    /**
     * @dev Consolidated function to read all vault states in one call.
     * Returns: balance, totalReceived, totalDistributed, lastBuybackTime, todayBuybackCount, isReady
     */
    function getVaultState() external view returns (
        uint256 balance,
        uint256 received,
        uint256 distributed,
        uint256 lastBuyback,
        uint256 todayCount,
        bool ready
    ) {
        uint256 count = buybacksToday;
        if (block.timestamp >= dayStartTime + DAY_DURATION) count = 0;
        
        return (
            address(this).balance,
            totalBNBReceived,
            totalBNBDistributed,
            lastBuybackTime,
            count,
            shouldExecuteBuyback()
        );
    }
}
