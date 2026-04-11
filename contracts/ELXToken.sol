// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Interfaces
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


contract ELXToken is ERC20, Ownable, ReentrancyGuard {
    // Supply
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BURN_AMOUNT = 400_000_000 * 10 ** 18;
    uint256 public constant LP_AMOUNT = 600_000_000 * 10 ** 18;

    // Taxes
    uint256 public buyTaxPercent = 5;
    uint256 public sellTaxPercent = 5;

    // Tax distribution (out of 500 bps)
    uint256 public constant DEV_TAX_BPS = 30;      // 0.3%
    uint256 public constant RESERVE_TAX_BPS = 30;  // 0.3%
    uint256 public constant BUYBACK_TAX_BPS = 440; // 4.4%

    // Buyback split (out of 1000)
    uint256 public constant BUYBACK_LIQUIDITY_BPS = 450; // 45%
    uint256 public constant BUYBACK_BURN_BPS = 485;      // 48.5%
    uint256 public constant BUYBACK_REWARDS_BPS = 65;    // 6.5%

    // Addresses
    address public devWallet;
    address public reserveVault;
    address public rewardsVault;

    // Tax accumulation
    uint256 public tokensForTax;
    uint256 public swapTokensAtAmount = 1_000 * 10 ** 18;

    // Router & Pair
    address public pancakePair;
    IUniswapV2Router02 public pancakeRouter;
    address public WBNB;

    // Slippage protection (5% default)
    uint16 public slippageBps = 500;

    // Internal state
    bool private swapping;
    mapping(address => bool) private _isExcludedFromFees;

    // Tracking & diagnostics
    uint256 public totalBNBToReserve;
    uint256 public totalBNBToBuyback;
    uint256 public pendingBuybackBNB;
    address public lpTokenRecipient;

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    // Last operation status (for monitoring)
    bool public lastRewardsFailed;
    bool public lastBuybackFailed;
    bool public lastLiquidityFailed;

    // Events
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
    event PendingBuybackUpdated(uint256 amount);

    modifier lockTheSwap() {
        swapping = true;
        _;
        swapping = false;
    }

    constructor(
        string memory name,
        string memory symbol,
        address routerAddress,
        address _devWallet,
        address _reserveVault,
        address _rewardsVault
    ) ERC20(name, symbol) {
        _mint(msg.sender, TOTAL_SUPPLY);
        _burn(msg.sender, BURN_AMOUNT);

        devWallet = _devWallet == address(0) ? msg.sender : _devWallet;
        reserveVault = _reserveVault;
        rewardsVault = _rewardsVault;

        if (routerAddress != address(0)) {
            pancakeRouter = IUniswapV2Router02(routerAddress);
            WBNB = pancakeRouter.WETH();
        }

        lpTokenRecipient = BURN_ADDRESS;
        _isExcludedFromFees[msg.sender] = true;
        _isExcludedFromFees[address(this)] = true;
    }

    // View functions
    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function tokensAccumulatedForTax() external view returns (uint256) {
        return tokensForTax;
    }

    function getTotalLogs() external view returns (uint256 toReserve, uint256 toBuyback) {
        return (totalBNBToReserve, totalBNBToBuyback);
    }

    receive() external payable {}

    // Transfer with tax logic
    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0) && to != address(0), "Zero address");
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        // Skip tax for excluded addresses
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            super._transfer(from, to, amount);
            return;
        }

        // Auto-detect pair if not set
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

        super._transfer(from, to, amount - taxAmount);

        // Trigger tax processing when threshold is reached during buy/sell
        if (!swapping && tokensForTax >= swapTokensAtAmount) {
            if (pancakePair != address(0) && (to == pancakePair || from == pancakePair) && _msgSender() != address(pancakeRouter)) {
                _processTaxSwap(tokensForTax);
            }
        }
    }

    function _processTaxSwap(uint256 amountToSwap) internal lockTheSwap {
        if (amountToSwap == 0) return;
        bool swapped = _distributeTaxes(amountToSwap);
        if (swapped) {
            tokensForTax = tokensForTax >= amountToSwap ? tokensForTax - amountToSwap : 0;
        }
    }

    function _getAmountOutMin(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        if (address(pancakeRouter) == address(0) || slippageBps >= 10000) return 0;

        try pancakeRouter.getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            return amounts.length > 0 
                ? (amounts[amounts.length - 1] * (10000 - slippageBps)) / 10000 
                : 0;
        } catch {
            return 0;
        }
    }

    // Main tax distribution logic
    function _distributeTaxes(uint256 tokenAmount) internal returns (bool) {
        if (tokenAmount == 0 || address(pancakeRouter) == address(0)) return false;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 initialBalance = address(this).balance;

        lastRewardsFailed = false;
        lastBuybackFailed = false;
        lastLiquidityFailed = false;

        // Split between reserve and buyback
        uint256 totalTaxBps = RESERVE_TAX_BPS + BUYBACK_TAX_BPS;
        uint256 tokensForReserve = (tokenAmount * RESERVE_TAX_BPS) / totalTaxBps;
        uint256 tokensBuyback = tokenAmount - tokensForReserve;

        // For liquidity: keep half the LP tokens, swap the rest + everything else in one go
        uint256 tokensForLP = (tokensBuyback * BUYBACK_LIQUIDITY_BPS) / 1000;
        uint256 tokensForLP_half = tokensForLP / 2;
        uint256 tokensToSwap = tokenAmount - tokensForLP_half;

        // Single swap: everything except half LP tokens → BNB
        if (tokensToSwap > 0) {
            _approve(address(this), address(pancakeRouter), tokensToSwap);
            uint256 minOutSwap = _getAmountOutMin(tokensToSwap, path);

            try pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokensToSwap, minOutSwap, path, address(this), block.timestamp
            ) {} catch {
                emit SwapTokensForBNB(tokenAmount, 0);
                return false;
            }
        }

        uint256 bnbReceived = address(this).balance - initialBalance;
        if (bnbReceived == 0) {
            emit SwapTokensForBNB(tokenAmount, 0);
            emit TaxDistributed(0, 0, 0);
            return true;
        }

        // Split received BNB according to original ratio
        uint256 bnbToReserve = (tokensToSwap == 0) ? 0 : (bnbReceived * tokensForReserve) / tokensToSwap;
        uint256 bnbToBuyback = bnbReceived - bnbToReserve;

        // Send to reserve
        if (bnbToReserve > 0) {
            require(reserveVault != address(0), "Reserve vault not set");
            (bool ok, ) = payable(reserveVault).call{value: bnbToReserve}("");
            require(ok, "Reserve transfer failed");
            totalBNBToReserve += bnbToReserve;
        }

        // Process buyback portion
        if (bnbToBuyback > 0) {
            uint256 effectiveBuyback = bnbToBuyback + pendingBuybackBNB;
            pendingBuybackBNB = 0;
            totalBNBToBuyback += effectiveBuyback;

            uint256 bnbForLiquidity = (effectiveBuyback * BUYBACK_LIQUIDITY_BPS) / 1000;
            uint256 bnbForBurn = (effectiveBuyback * BUYBACK_BURN_BPS) / 1000;
            uint256 bnbForRewards = effectiveBuyback - bnbForLiquidity - bnbForBurn;

            // Send rewards
            if (bnbForRewards > 0 && rewardsVault != address(0)) {
                (bool rewardsOk, ) = payable(rewardsVault).call{value: bnbForRewards}("");
                if (!rewardsOk) {
                    emit RewardsTransferFailed(bnbForRewards);
                    lastRewardsFailed = true;
                }
            }

            // Buy & burn tokens
            if (bnbForBurn > 0) {
                address[] memory buyPath = new address[](2);
                buyPath[0] = WBNB;
                buyPath[1] = address(this);

                try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbForBurn}(
                    0, buyPath, BURN_ADDRESS, block.timestamp
                ) {
                    lastBuybackFailed = false;
                } catch Error(string memory reason) {
                    lastBuybackFailed = true;
                    emit BuybackFailed(bnbForBurn);
                    emit BuybackFailedDetailed(reason);
                } catch (bytes memory) {
                    lastBuybackFailed = true;
                    emit BuybackFailed(bnbForBurn);
                    emit BuybackFailedDetailed("Low-level revert");
                }
            }

            // Add liquidity with spared tokens + BNB
            if (bnbForLiquidity > 0 && tokensForLP_half > 0) {
                _approve(address(this), address(pancakeRouter), tokensForLP_half);

                try pancakeRouter.addLiquidityETH{value: bnbForLiquidity}(
                    address(this), tokensForLP_half, 0, 0, lpTokenRecipient, block.timestamp
                ) returns (uint amountToken, uint amountETH, uint liquidity) {
                    emit LiquidityAdded(amountToken, amountETH, liquidity);
                    lastLiquidityFailed = false;
                } catch Error(string memory reason) {
                    lastLiquidityFailed = true;
                    emit LiquidityFailed(bnbForLiquidity);
                    emit LiquidityFailedDetailed(reason);
                } catch (bytes memory) {
                    lastLiquidityFailed = true;
                    emit LiquidityFailed(bnbForLiquidity);
                    emit LiquidityFailedDetailed("Low-level revert");
                }
            } else if (bnbForLiquidity > 0) {
                pendingBuybackBNB += bnbForLiquidity;
                emit PendingBuybackUpdated(bnbForLiquidity);
            }

            // Sweep any leftover BNB (dust from router, failed sends, etc.)
            if (address(this).balance > 0) {
                uint256 dust = address(this).balance;
                pendingBuybackBNB += dust;
                emit PendingBuybackUpdated(dust);
            }

            // Carry over any leftover tokens (due to pair ratio) for next cycle
            uint256 leftoverTokens = balanceOf(address(this));
            if (leftoverTokens > 0) {
                tokensForTax += leftoverTokens;
            }
        }

        emit SwapTokensForBNB(tokenAmount, bnbReceived);
        emit TaxDistributed(0, bnbToReserve, bnbToBuyback);
        return true;
    }

    // Helper to decode low-level revert messages (For testing)
    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction reverted silently";
        bytes memory revertData = _returnData;
        assembly { revertData := add(revertData, 0x04) }
        return abi.decode(revertData, (string));
    }

    // Owner can manually trigger tax swap if wanted
    function swapCollectedTaxesNow(uint256 amount) external onlyOwner lockTheSwap nonReentrant {
        if (amount == 0) return;

        uint256 available = balanceOf(address(this));
        uint256 toSwap = amount > tokensForTax ? tokensForTax : amount;
        if (toSwap > available) toSwap = available;
        if (toSwap == 0) return;

        bool swapped = _distributeTaxes(toSwap);
        if (swapped) {
            tokensForTax = tokensForTax >= toSwap ? tokensForTax - toSwap : 0;
        }
    }

    // Public burn functions
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _approve(account, msg.sender, allowance(account, msg.sender) - amount);
        _burn(account, amount);
    }
}