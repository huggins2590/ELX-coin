// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IPancakePair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint wad) external;
    function transfer(address to, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint amountOutMin, address[] calldata path, address to, uint deadline) external payable;
    function addLiquidityETH(address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IPancakeSwapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IReserveVault {
    function shouldExecuteBuyback() external view returns (bool);
    function executeBuyback() external;
}

// ELX Token: A deflationary token with automated tax distribution, buybacks, and rewards
contract ELXToken is ERC20, Ownable, ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BURN_AMOUNT = 400_000_000 * 10 ** 18;
    uint256 public constant LP_AMOUNT = 600_000_000 * 10 ** 18;

    uint256 public buyTaxPercent = 5;
    uint256 public sellTaxPercent = 5;

    // Percentages for tax distribution
    uint256 public constant DEV_TAX_BPS = 30; // 0.3%
    uint256 public constant RESERVE_TAX_BPS = 30; // 0.3%
    uint256 public constant BUYBACK_TAX_BPS = 440; // 4.4%

    // Breakdown of the buyback portion
    uint256 public constant BUYBACK_LIQUIDITY_BPS = 450; 
    uint256 public constant BUYBACK_BURN_BPS = 485; 
    uint256 public constant BUYBACK_REWARDS_BPS = 65; 

    address public devWallet;
    address public reserveVault;
    address public rewardsVault;
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    uint256 public tokensForTax;
    uint256 public swapTokensAtAmount = 1_000 * 10 ** 18;

    address public pancakePair;
    IUniswapV2Router02 public pancakeRouter;
    address public WBNB;

    uint16 public slippageBps = 500; 

    bool private swapping;
    mapping(address => bool) private _isExcludedFromFees;

    uint256 public totalBNBToReserve;
    uint256 public totalBNBToBuyback;
    uint256 public pendingBuybackBNB;
    address public lpTokenRecipient;

    // Track status of internal functions
    bool public lastRewardsFailed;
    bool public lastBuybackFailed;
    bool public lastLiquidityFailed;

    // Reward eligibility tracking
    mapping(address => uint256) public holderSince;
    uint256 public rewardThreshold = 50000 * 10**18;
    uint256 public eligibleHoldersCount;

    // Reserve buyback flag system (Either-Or priority)
    bool public buybackPending;

    // Sell volume tracking: 12 buckets x 5 minutes = 60-minute window
    uint256[12] public sellBuckets;
    uint256 public currentBucketIndex;
    uint256 public currentBucketStart;
    uint256 public constant BUCKET_DURATION = 5 minutes;
    uint256 public constant NUM_BUCKETS = 12;

    // Sell pressure threshold: 50 bps = 0.5% of circulating supply
    uint256 public sellPressureThresholdBps = 50;

    event BuybackBurn(uint256 bnbSpent, uint256 tokensBurned);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 liquidity);
    event RewardsFailed(uint256 amount);
    event BuybackFailed(uint256 amount);
    event LiquidityFailed(uint256 amount);
    event BuybackFailedDetailed(string reason);
    event LiquidityFailedDetailed(string reason);
    event TaxesUpdated(uint256 buyPercent, uint256 sellPercent);
    event SwapTokensForBNB(uint256 tokenAmount, uint256 bnbReceived);
    event TaxTaken(address indexed from, address indexed to, uint256 amount);
    event TaxDistributed(uint256 devTokens, uint256 bnbToReserve, uint256 bnbToBuyback);
    event ReserveTransferFailed(uint256 amount);
    event RewardsTransferFailed(uint256 amount);
    event SellVolumeUpdated(uint256 totalVolume, uint256 threshold);
    event ReserveBuybackDeferred(uint256 timestamp);
    event ReserveBuybackTriggered(uint256 timestamp);

    modifier lockTheSwap() {
        swapping = true;
        _;
        swapping = false;
    }

    constructor(string memory name, string memory symbol, address routerAddress, address _devWallet) ERC20(name, symbol) {
        _mint(msg.sender, TOTAL_SUPPLY);
        _burn(msg.sender, BURN_AMOUNT);

        devWallet = _devWallet == address(0) ? msg.sender : _devWallet;
        pancakeRouter = IUniswapV2Router02(routerAddress);
        WBNB = pancakeRouter.WETH();

        lpTokenRecipient = BURN_ADDRESS;
        _isExcludedFromFees[msg.sender] = true;
        _isExcludedFromFees[address(this)] = true;
    }

    function isExcludedFromFees(address account) external view returns (bool) { return _isExcludedFromFees[account]; }
    receive() external payable {}
    function tokensAccumulatedForTax() external view returns (uint256) { return tokensForTax; }
    function getTotalLogs() external view returns (uint256 toReserve, uint256 toBuyback) { return (totalBNBToReserve, totalBNBToBuyback); }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0) && to != address(0), "Zero address");
        if (amount == 0) { super._transfer(from, to, 0); return; }
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) { super._transfer(from, to, amount); return; }

        if (pancakePair == address(0) && address(pancakeRouter) != address(0)) {
            try IPancakeSwapV2Factory(pancakeRouter.factory()).getPair(address(this), WBNB) returns (address pair) {
                pancakePair = pair;
            } catch {}
        }

        uint256 taxAmount = 0;
        if (from == pancakePair && buyTaxPercent > 0) {
            taxAmount = (amount * buyTaxPercent) / 100;
        } else if (to == pancakePair && sellTaxPercent > 0) {
            taxAmount = (amount * sellTaxPercent) / 100;
        }

        if (taxAmount > 0) {
            uint256 devAmount = (taxAmount * DEV_TAX_BPS) / 500;
            uint256 reserveAmount = (taxAmount * RESERVE_TAX_BPS) / 500;
            uint256 buybackAmount = (taxAmount * BUYBACK_TAX_BPS) / 500;

            if (devAmount > 0 && devWallet != address(0)) {
                super._transfer(from, devWallet, devAmount);
            }

            uint256 toBNBAmount = reserveAmount + buybackAmount;
            if (toBNBAmount > 0) {
                super._transfer(from, address(this), toBNBAmount);
                tokensForTax += toBNBAmount;
            }

            emit TaxTaken(from, to, taxAmount);
        }

        // Record sell volume for reserve buyback tracking
        if (to == pancakePair && pancakePair != address(0)) {
            _recordSellVolume(amount);
        }

        // Either-Or Priority Logic: Handle "Pancake: LOCKED" by deferring buybacks during trades
        if (!swapping) {
            bool isPairTrade = pancakePair != address(0) && (to == pancakePair || from == pancakePair);
            bool taxSwapReady = isPairTrade && tokensForTax >= swapTokensAtAmount;
            bool buybackTriggered = isPairTrade && _isReserveBuybackReady();
            
            bool buybackReady = buybackPending || buybackTriggered;

            if (taxSwapReady) {
                _processTaxSwap(tokensForTax);
                if (buybackReady && !buybackPending) {
                    buybackPending = true;
                    emit ReserveBuybackDeferred(block.timestamp);
                }
            } else if (buybackReady && reserveVault != address(0)) {
                if (isPairTrade) {
                    if (!buybackPending) {
                        buybackPending = true;
                        emit ReserveBuybackDeferred(block.timestamp);
                    }
                } else {
                    buybackPending = false;
                    _executeReserveBuyback();
                }
            }
        }

        super._transfer(from, to, amount - taxAmount);

        _updateHolderTimer(from);
        _updateHolderTimer(to);
    }

    function _processTaxSwap(uint256 amountToSwap) internal lockTheSwap {
        if (amountToSwap == 0) return;
        bool swapped = _distributeTaxes(amountToSwap);
        if (swapped) {
            if (tokensForTax >= amountToSwap) tokensForTax -= amountToSwap; else tokensForTax = 0;
        }
    }

    function _getAmountOutMin(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        if (address(pancakeRouter) == address(0) || slippageBps >= 10000) return 0;
        try pancakeRouter.getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            if (amounts.length == 0) return 0;
            uint256 out = amounts[amounts.length - 1];
            return (out * (10000 - slippageBps)) / 10000;
        } catch {
            return 0;
        }
    }

    // Handles the conversion of tokens to BNB and distribution to vaults/LP
    function _distributeTaxes(uint256 tokenAmount) internal returns (bool) {
        if (tokenAmount == 0 || address(pancakeRouter) == address(0)) return false;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 initialBalance = address(this).balance;
        lastRewardsFailed = false; lastBuybackFailed = false; lastLiquidityFailed = false;

        uint256 totalTaxBps = RESERVE_TAX_BPS + BUYBACK_TAX_BPS; 
        if (totalTaxBps == 0) return false;

        uint256 tokensForReserve = (tokenAmount * RESERVE_TAX_BPS) / totalTaxBps;
        uint256 tokensBuyback = tokenAmount - tokensForReserve;

        // Keep half of LP tokens for liquidity, swap the rest
        uint256 tokensForLP = (tokensBuyback * BUYBACK_LIQUIDITY_BPS) / 1000;
        uint256 tokensForLP_half = tokensForLP / 2;           
        
        uint256 tokensForRewards = (tokensBuyback * BUYBACK_REWARDS_BPS) / 1000;
        if (tokensForRewards > 0 && rewardsVault != address(0)) {
            super._transfer(address(this), rewardsVault, tokensForRewards);
        }

        uint256 tokensToSwap = tokenAmount - tokensForLP_half - tokensForRewards;

        // Convert tokens to BNB
        bool swapSucceeded = true;
        if (tokensToSwap > 0) {
            _approve(address(this), address(pancakeRouter), tokensToSwap);
            uint256 minOutSwap = _getAmountOutMin(tokensToSwap, path);
            try pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(tokensToSwap, minOutSwap, path, address(this), block.timestamp) {
                // success
            } catch {
                emit SwapTokensForBNB(tokenAmount, 0);
                swapSucceeded = false;
            }
        }
        if (!swapSucceeded) return false;

        uint256 bnbReceived = address(this).balance - initialBalance;
        if (bnbReceived == 0) {
            emit SwapTokensForBNB(tokenAmount, 0);
            return true;
        }

        // Split BNB between Reserve and Buyback Engine
        // We use tokensToSwap as the base because that's what generated the bnbReceived
        uint256 bnbToReserve = (tokensToSwap == 0) ? 0 : (bnbReceived * tokensForReserve) / tokensToSwap;
        if (bnbToReserve > bnbReceived) bnbToReserve = bnbReceived;
        uint256 bnbToBuyback = bnbReceived - bnbToReserve;

        if (bnbToReserve > 0 && reserveVault != address(0)) {
            (bool ok, ) = payable(reserveVault).call{value: bnbToReserve}("");
            if (ok) totalBNBToReserve += bnbToReserve;
        }

        if (bnbToBuyback > 0) {
            uint256 effectiveBuyback = bnbToBuyback + pendingBuybackBNB;
            pendingBuybackBNB = 0;
            totalBNBToBuyback += effectiveBuyback;

            // Step A: Add liquidity first (uses a portion of BNB and the reserved ELX tokens)
            uint256 bnbForLiquidity = (effectiveBuyback * BUYBACK_LIQUIDITY_BPS) / 1000;
            if (bnbForLiquidity > 0 && tokensForLP_half > 0) {
                _approve(address(this), address(pancakeRouter), tokensForLP_half);
                try pancakeRouter.addLiquidityETH{ value: bnbForLiquidity }(
                    address(this), 
                    tokensForLP_half, 
                    0, 0, 
                    lpTokenRecipient, 
                    block.timestamp
                ) returns (uint amountToken, uint amountETH, uint) {
                    emit LiquidityAdded(amountToken, amountETH, 0);
                    lastLiquidityFailed = false;
                } catch {
                    lastLiquidityFailed = true;
                }
            }

            // Step B: Use ALL remaining BNB for Buyback & Burn (minimizes BNB dust)
            uint256 bnbRemaining = address(this).balance - initialBalance;
            if (bnbRemaining > 0) {
                address[] memory buyPath = new address[](2);
                buyPath[0] = WBNB; buyPath[1] = address(this);
                try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbRemaining }(
                    0, 
                    buyPath, 
                    BURN_ADDRESS, 
                    block.timestamp
                ) {
                    lastBuybackFailed = false;
                } catch {
                    lastBuybackFailed = true;
                    pendingBuybackBNB = bnbRemaining; // Only save if swap fails
                    emit BuybackFailed(bnbRemaining);
                }
            }

            // Capture any dust BNB
            if (address(this).balance > 0) {
                pendingBuybackBNB += address(this).balance;
            }

            // Burn any leftover tokens to ensure zero dust
            uint256 leftoverTokens = balanceOf(address(this));
            if (leftoverTokens > 0) {
                super._transfer(address(this), BURN_ADDRESS, leftoverTokens);
            }
        }

        emit SwapTokensForBNB(tokenAmount, bnbReceived);
        return true;
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction reverted silently";
        bytes memory revertData = _returnData;
        assembly { revertData := add(revertData, 0x04) }
        return abi.decode(revertData, (string));
    }

    // Manual trigger for tax distribution (Owner only)
    function swapCollectedTaxesNow(uint256 amount) external onlyOwner lockTheSwap nonReentrant {
        if (amount == 0) return;
        uint256 available = balanceOf(address(this));
        uint256 toSwap = amount > tokensForTax ? tokensForTax : amount;
        if (toSwap > available) toSwap = available;
        if (toSwap == 0) return;
        
        if (_distributeTaxes(toSwap)) {
            tokensForTax = tokensForTax >= toSwap ? tokensForTax - toSwap : 0;
        }
    }

    function burn(uint256 amount) external { _burn(msg.sender, amount); }
    function burnFrom(address account, uint256 amount) external { _approve(account, msg.sender, allowance(account, msg.sender) - amount); _burn(account, amount); }

    // Sell volume tracking: gas-efficient 5-minute bucket system
    function _recordSellVolume(uint256 amount) internal {
        // Initialize bucket start on first call
        if (currentBucketStart == 0) {
            currentBucketStart = block.timestamp;
        }

        // Check if we need to rotate to next bucket(s)
        uint256 elapsed = block.timestamp - currentBucketStart;
        if (elapsed >= BUCKET_DURATION) {
            uint256 bucketsToAdvance = elapsed / BUCKET_DURATION;
            if (bucketsToAdvance >= NUM_BUCKETS) {
                // More than 60 minutes passed — wipe everything
                for (uint256 i = 0; i < NUM_BUCKETS; i++) {
                    sellBuckets[i] = 0;
                }
                currentBucketIndex = 0;
            } else {
                // Clear the buckets we're advancing through
                for (uint256 i = 0; i < bucketsToAdvance; i++) {
                    currentBucketIndex = (currentBucketIndex + 1) % NUM_BUCKETS;
                    sellBuckets[currentBucketIndex] = 0;
                }
            }
            currentBucketStart = block.timestamp;
        }

        // Record this sell in the current bucket
        sellBuckets[currentBucketIndex] += amount;
    }

    // Get total sell volume across all 12 buckets (last ~60 minutes)
    function getSellVolumeLastHour() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < NUM_BUCKETS; i++) {
            total += sellBuckets[i];
        }
        return total;
    }

    // Check if reserve buyback conditions are met
    function _isReserveBuybackReady() internal view returns (bool) {
        if (reserveVault == address(0)) return false;
        try IReserveVault(reserveVault).shouldExecuteBuyback() returns (bool ready) {
            return ready;
        } catch {
            return false;
        }
    }

    // Execute the reserve buyback via the vault
    function _executeReserveBuyback() internal lockTheSwap {
        try IReserveVault(reserveVault).executeBuyback() {
            emit ReserveBuybackTriggered(block.timestamp);
        } catch {
            // Safety: Buyback failure should not block user transfers
        }
    }

    // Owner can adjust sell pressure threshold
    function setSellPressureThreshold(uint256 _bps) external onlyOwner {
        require(_bps > 0 && _bps <= 1000, "1-1000 bps");
        sellPressureThresholdBps = _bps;
    }

    function setSwapTokensAtAmount(uint256 amount) external onlyOwner {
        swapTokensAtAmount = amount;
    }

    function setVaults(address _reserveVault, address _rewardsVault) external onlyOwner {
        require(reserveVault == address(0) && rewardsVault == address(0), "Vaults already set");
        reserveVault = _reserveVault;
        rewardsVault = _rewardsVault;
        _isExcludedFromFees[_reserveVault] = true;
        _isExcludedFromFees[_rewardsVault] = true;
    }

    function setRewardThreshold(uint256 _threshold) external onlyOwner {
        rewardThreshold = _threshold;
    }

    function resetRewardTimer(address account) external {
        require(msg.sender == rewardsVault, "Only rewards vault");
        holderSince[account] = balanceOf(account) >= rewardThreshold ? block.timestamp : 0;
    }

    // Updates the holding timer when balances change
    function _updateHolderTimer(address account) internal {
        if (account == address(0) || account == pancakePair || _isExcludedFromFees[account]) return;
        
        uint256 balance = balanceOf(account);
        if (balance >= rewardThreshold) {
            if (holderSince[account] == 0) {
                holderSince[account] = block.timestamp;
                eligibleHoldersCount++;
            }
        } else {
            if (holderSince[account] != 0) {
                holderSince[account] = 0;
                if (eligibleHoldersCount > 0) eligibleHoldersCount--;
            }
        }
    }
}