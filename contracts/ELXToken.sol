// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IReserveVault {
    function shouldExecuteBuyback() external view returns (bool);
    function executeBuyback() external;
}

// ELX token with tax distribution, buybacks, liquidity and rewards handling
contract ELXToken is ERC20, ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BURN_AMOUNT = 400_000_000 * 10 ** 18;
    uint256 public constant LP_AMOUNT = 600_000_000 * 10 ** 18;

    uint256 public constant buyTaxPercent = 5;
    uint256 public constant sellTaxPercent = 5;

    // BPS: 10,000 = 100%.
    // Layer 1: Split of the total tax (5% => 500 BPS)
    uint256 public constant TAX_SHARE_DEV_BPS = 30;      // 0.3% of total transaction
    uint256 public constant TAX_SHARE_RESERVE_BPS = 30;  // 0.3% of total transaction
    uint256 public constant TAX_SHARE_BUYBACK_BPS = 440; // 4.4% of total transaction

    // Layer 2: Distribution of the buyback portion (10000 = 100%)
    uint256 public constant DISTRIBUTION_LIQUIDITY_BPS = 4500; // 45.0% of the buyback portion
    uint256 public constant DISTRIBUTION_BURN_BPS = 4850;      // 48.5% of the buyback portion
    uint256 public constant DISTRIBUTION_REWARDS_BPS = 650;    // 6.5% of the buyback portion

    address public immutable devWallet;
    address public reserveVault;
    address public rewardsVault;
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    uint256 public tokensForTax;
    uint256 public constant SWAP_TOKENS_AT_AMOUNT = 10_000 * 10 ** 18;

    address public pancakePair;
    IUniswapV2Router02 public immutable pancakeRouter;
    address public immutable WBNB;
    uint16 public constant slippageBps = 1000; 

    // Swap guard
    bool private swapping;
    address public immutable vaultSetter;
    mapping(address => bool) public _isExcludedFromFees;

    uint256 public totalBNBToReserve;
    uint256 public totalBNBToBuyback;
    uint256 public pendingBuybackBNB;

    // Flags indicating last swap/buyback/liquidity outcomes
    bool public lastRewardsFailed;
    bool public lastBuybackFailed;
    bool public lastLiquidityFailed;

    // Reward eligibility tracking
    mapping(address => uint256) public holderSince;
    uint256 public constant REWARD_THRESHOLD = 50000 * 10**18;
    uint256 public eligibleHoldersCount;

    // Sell volume tracking: 12 x 5-minute buckets (~60 minutes)
    uint256[12] public sellBuckets;
    uint256 public currentBucketIndex;
    uint256 public currentBucketStart;
    uint256 public constant BUCKET_DURATION = 5 minutes;
    uint256 public constant NUM_BUCKETS = 12;

    uint256 public constant SELL_PRESSURE_THRESHOLD_BPS = 150; // 1.5% threshold for reserve buyback

    event BuybackBurn(uint256 bnbSpent, uint256 tokensBurned);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 liquidity);

    event TaxesUpdated(uint256 buyPercent, uint256 sellPercent);
    event SwapTokensForBNB(uint256 tokenAmount, uint256 bnbReceived);
    event TaxTaken(address indexed from, address indexed to, uint256 amount);
    event TaxDistributed(uint256 devTokens, uint256 bnbToReserve, uint256 bnbToBuyback);

    event SellVolumeUpdated(uint256 totalVolume, uint256 threshold);
    event ReserveBuybackTriggered(uint256 timestamp);
    event VaultsSet(address indexed reserveVault, address indexed rewardsVault, address indexed pancakePair);

    modifier lockTheSwap() {
        swapping = true;
        _;
        swapping = false;
    }

    modifier onlyVaultSetter() {
        require(msg.sender == vaultSetter, "Not vault setter");
        _;
    }

    constructor(string memory _name, string memory _symbol, address routerAddress, address _devWallet) ERC20(_name, _symbol) {
        _mint(msg.sender, TOTAL_SUPPLY);
        _burn(msg.sender, BURN_AMOUNT);
         require(routerAddress != address(0) && _devWallet != address(0), "Zero address");

        vaultSetter = msg.sender;
        devWallet = _devWallet;
        pancakeRouter = IUniswapV2Router02(routerAddress);
        WBNB = pancakeRouter.WETH();
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


        uint256 taxAmount = 0;
        if (from == pancakePair && buyTaxPercent > 0) {
            taxAmount = (amount * buyTaxPercent) / 100;
        } else if (to == pancakePair && sellTaxPercent > 0) {
            taxAmount = (amount * sellTaxPercent) / 100;
        }

        if (taxAmount > 0) {
            uint256 devAmount = (taxAmount * TAX_SHARE_DEV_BPS) / 500;
            uint256 reserveAmount = (taxAmount * TAX_SHARE_RESERVE_BPS) / 500;
            uint256 buybackAmount = (taxAmount * TAX_SHARE_BUYBACK_BPS) / 500;

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

            // Priority: on sells, try reserve buyback first; otherwise swap taxes when threshold reached.
        if (!swapping && to == pancakePair && pancakePair != address(0)) {
            if (_isReserveBuybackReady()) {
                _executeReserveBuyback();
            } else if (tokensForTax >= SWAP_TOKENS_AT_AMOUNT) {
                _processTaxSwap(tokensForTax);
            }
        }

        super._transfer(from, to, amount - taxAmount);
    }

    // Automatically manage holder timers on all transfers, mints, and burns
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
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
        lastRewardsFailed = false; 
        lastBuybackFailed = false; 
        lastLiquidityFailed = false;


        uint256 totalTaxBps = TAX_SHARE_RESERVE_BPS + TAX_SHARE_BUYBACK_BPS; 
        if (totalTaxBps == 0) return false;

        uint256 tokensForReserve = (tokenAmount * TAX_SHARE_RESERVE_BPS) / totalTaxBps;
        uint256 tokensBuyback = tokenAmount - tokensForReserve;

        // Keep half of LP tokens for liquidity, swap the rest
        uint256 tokensForLP = (tokensBuyback * DISTRIBUTION_LIQUIDITY_BPS) / 10000;
        uint256 tokensForLP_half = tokensForLP / 2;           
        
        // Rewards will be processed from the buyback BNB instead of direct tokens
        uint256 tokensToSwap = tokenAmount - tokensForLP_half;

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
            return true; // Return true because tokens are gone from the contract even if BNB was 0
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
            uint256 bnbForLiquidity = (effectiveBuyback * DISTRIBUTION_LIQUIDITY_BPS) / 10000;
            if (bnbForLiquidity > 0 && tokensForLP_half > 0) {
                _approve(address(this), address(pancakeRouter), tokensForLP_half);
                
                uint256 amountTokenMin = (tokensForLP_half * (10000 - slippageBps)) / 10000;
                uint256 amountETHMin = (bnbForLiquidity * (10000 - slippageBps)) / 10000;
                
                try pancakeRouter.addLiquidityETH{ value: bnbForLiquidity }(
                    address(this), 
                    tokensForLP_half, 
                    amountTokenMin, 
                    amountETHMin, 
                    BURN_ADDRESS, 
                    block.timestamp
                ) returns (uint amountToken, uint amountETH, uint) {
                    emit LiquidityAdded(amountToken, amountETH, 0);
                    lastLiquidityFailed = false;
                } catch {
                    lastLiquidityFailed = true;
                }
            }

            // Step B: Use ALL remaining BNB for Buyback & Distribute (minimizes BNB dust)
            uint256 bnbRemaining = address(this).balance - initialBalance;
            if (bnbRemaining > 0) {
                address[] memory buyPath = new address[](2);
                buyPath[0] = WBNB; buyPath[1] = address(this);
                
                uint256 totalSplitBps = DISTRIBUTION_REWARDS_BPS + DISTRIBUTION_BURN_BPS;
                uint256 bnbForRewards = (bnbRemaining * DISTRIBUTION_REWARDS_BPS) / totalSplitBps;
                uint256 bnbForBurn = bnbRemaining - bnbForRewards;

                bool swapRewardsFailed = false;
                bool swapBurnFailed = false;

                if (bnbForRewards > 0 && rewardsVault != address(0)) {
                    uint256 minOutRewards = _getAmountOutMin(bnbForRewards, buyPath);
                    try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbForRewards }(
                        minOutRewards, buyPath, rewardsVault, block.timestamp
                    ) {} catch { swapRewardsFailed = true; }
                }

                if (bnbForBurn > 0) {
                    uint256 minOutBurn = _getAmountOutMin(bnbForBurn, buyPath);
                    try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbForBurn }(
                        minOutBurn, buyPath, BURN_ADDRESS, block.timestamp
                    ) {} catch { swapBurnFailed = true; }
                }

                if (swapRewardsFailed || swapBurnFailed) {
                    lastBuybackFailed = true;
                } else {
                    lastBuybackFailed = false;
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

    function setVaults(address _reserveVault, address _rewardsVault, address _pancakePair) external onlyVaultSetter {
        require(reserveVault == address(0) && rewardsVault == address(0), "Vaults already set");
        require(_reserveVault != address(0) && _rewardsVault != address(0) && _pancakePair != address(0), "Zero address");
        
        reserveVault = _reserveVault;
        rewardsVault = _rewardsVault;
        pancakePair = _pancakePair;

        _isExcludedFromFees[_reserveVault] = true;
        _isExcludedFromFees[_rewardsVault] = true;
        emit VaultsSet(_reserveVault, _rewardsVault, _pancakePair);
    }

    function resetRewardTimer(address account) external {
        require(msg.sender == rewardsVault, "Only rewards vault");
        holderSince[account] = balanceOf(account) >= REWARD_THRESHOLD ? block.timestamp : 0;
    }

    // Updates the holding timer when balances change
    function _updateHolderTimer(address account) internal {
        if (account == address(0) || account == BURN_ADDRESS || account == pancakePair || _isExcludedFromFees[account]) return;
        
        uint256 balance = balanceOf(account);
        if (balance >= REWARD_THRESHOLD) {
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