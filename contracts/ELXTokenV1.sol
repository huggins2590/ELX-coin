// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// --- Interfaces (declared at top-level) ---
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

/**
 * @title ELXToken
 * @dev ERC20 token with tax, buyback-burn and auto-liquidity
 */
contract ELXTokenV1 is ERC20, Ownable, ReentrancyGuard {
    // supply
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BURN_AMOUNT = 400_000_000 * 10 ** 18;
    uint256 public constant LP_AMOUNT = 600_000_000 * 10 ** 18;

    // taxes
    uint256 public buyTaxPercent = 5;
    uint256 public sellTaxPercent = 5;

    // tax distribution (basis points relative to 500)
    uint256 public constant DEV_TAX_BPS = 30; // 0.3%
    uint256 public constant RESERVE_TAX_BPS = 30; // 0.3%
    uint256 public constant BUYBACK_TAX_BPS = 440; // 4.4%

    // buyback split (per-1000)
    uint256 public constant BUYBACK_LIQUIDITY_BPS = 450; // 45% of buyback
    uint256 public constant BUYBACK_BURN_BPS = 485; // 48.5% of buyback
    uint256 public constant BUYBACK_REWARDS_BPS = 65; // 6.5% of buyback

    // addresses
    address public devWallet;
    address public reserveVault;
    address public rewardsVault;

    // accumulation
    uint256 public tokensForTax;
    uint256 public swapTokensAtAmount = 1_000 * 10 ** 18;

    // router/pair
    address public pancakePair;
    IUniswapV2Router02 public pancakeRouter;
    address public WBNB;

    // slippage
    uint16 public slippageBps = 500; // 5%

    // guards
    bool private swapping;
    mapping(address => bool) private _isExcludedFromFees;

    // logging
    uint256 public totalBNBToReserve;
    uint256 public totalBNBToBuyback;
    uint256 public pendingBuybackBNB;
    address public lpTokenRecipient;
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    // diagnostic flags
    bool public lastRewardsFailed;
    bool public lastBuybackFailed;
    bool public lastLiquidityFailed;

    // events
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

    constructor(string memory name, string memory symbol, address routerAddress, address _devWallet, address _reserveVault, address _rewardsVault) ERC20(name, symbol) {
        _mint(msg.sender, TOTAL_SUPPLY);
        _burn(msg.sender, BURN_AMOUNT);

        devWallet = _devWallet == address(0) ? msg.sender : _devWallet;
        reserveVault = _reserveVault;
        rewardsVault = _rewardsVault;

        pancakeRouter = IUniswapV2Router02(routerAddress);
        WBNB = pancakeRouter.WETH();
        // attempt to fetch pair
        try IPancakeSwapV2Factory(pancakeRouter.factory()).getPair(address(this), WBNB) returns (address pair) {
            pancakePair = pair;
        } catch {
            pancakePair = address(0);
        }

        slippageBps = 500;
        lpTokenRecipient = BURN_ADDRESS;
        _isExcludedFromFees[msg.sender] = true;
        _isExcludedFromFees[address(this)] = true;
    }

    // --- utils ---
    function isExcludedFromFees(address account) external view returns (bool) { return _isExcludedFromFees[account]; }
    receive() external payable {}
    function tokensAccumulatedForTax() external view returns (uint256) { return tokensForTax; }
    function getTotalLogs() external view returns (uint256 toReserve, uint256 toBuyback) { return (totalBNBToReserve, totalBNBToBuyback); }

    // --- transfer/tax logic ---
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

        super._transfer(from, to, amount - taxAmount);

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

    // Distribute taxes: reserve tokens for LP, swap remainder to BNB, distribute BNB
    function _distributeTaxes(uint256 tokenAmount) internal returns (bool) {
        if (tokenAmount == 0 || address(pancakeRouter) == address(0)) return false;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        _approve(address(this), address(pancakeRouter), tokenAmount);

        uint256 initialBalance = address(this).balance;
        lastRewardsFailed = false; lastBuybackFailed = false; lastLiquidityFailed = false;

        uint256 totalTaxBps = RESERVE_TAX_BPS + BUYBACK_TAX_BPS; // 470
        if (totalTaxBps == 0) return false;

        // Determine token-side reserved for LP (from buyback portion)
        uint256 tokensBuyback = (tokenAmount * BUYBACK_TAX_BPS) / totalTaxBps;
        uint256 tokensForLP = (tokensBuyback * BUYBACK_LIQUIDITY_BPS) / 1000;
        if (tokensForLP > tokenAmount) tokensForLP = tokenAmount;
        uint256 tokensToSwap = tokenAmount - tokensForLP;

        bool swapSucceeded = true;
        if (tokensToSwap > 0) {
            uint256 minOutSwap = _getAmountOutMin(tokensToSwap, path);
            try pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(tokensToSwap, minOutSwap, path, address(this), block.timestamp) {
                swapSucceeded = true;
            } catch Error(string memory reason) {
                emit SwapTokensForBNB(tokenAmount, 0);
                swapSucceeded = false;
            } catch (bytes memory) {
                emit SwapTokensForBNB(tokenAmount, 0);
                swapSucceeded = false;
            }
        }
        if (!swapSucceeded) return false;

        uint256 bnbReceived = address(this).balance - initialBalance;
        if (bnbReceived == 0) { emit SwapTokensForBNB(tokenAmount, 0); emit TaxDistributed(0,0,0); return true; }

        uint256 bnbToReserve = (bnbReceived * RESERVE_TAX_BPS) / totalTaxBps;
        uint256 bnbToBuyback = bnbReceived - bnbToReserve;

        if (bnbToReserve > 0) {
            require(reserveVault != address(0), "Reserve vault not set");
            (bool ok, ) = payable(reserveVault).call{value: bnbToReserve}("");
            require(ok, "Reserve transfer failed");
            totalBNBToReserve += bnbToReserve;
        }

        if (bnbToBuyback > 0) {
            uint256 effectiveBuyback = bnbToBuyback + pendingBuybackBNB;
            pendingBuybackBNB = 0;
            totalBNBToBuyback += effectiveBuyback;

            uint256 bnbForLiquidity = (effectiveBuyback * BUYBACK_LIQUIDITY_BPS) / 1000;
            uint256 bnbForBurn = (effectiveBuyback * BUYBACK_BURN_BPS) / 1000;
            uint256 bnbForRewards = effectiveBuyback - bnbForLiquidity - bnbForBurn;

            uint256 bnbBeforeBuyback = address(this).balance;

            if (bnbForRewards > 0 && rewardsVault != address(0)) {
                (bool rewardsOk, ) = payable(rewardsVault).call{value: bnbForRewards}("");
                if (!rewardsOk) { emit RewardsTransferFailed(bnbForRewards); lastRewardsFailed = true; } else { lastRewardsFailed = false; }
            }

            // Buy tokens for burn and send directly to burn address
            if (bnbForBurn > 0) {
                address[] memory buyPath = new address[](2);
                buyPath[0] = WBNB; buyPath[1] = address(this);
                try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbForBurn }(0, buyPath, BURN_ADDRESS, block.timestamp) {
                    lastBuybackFailed = false;
                } catch Error(string memory reason) {
                    lastBuybackFailed = true; emit BuybackFailed(bnbForBurn); emit BuybackFailedDetailed(reason);
                } catch (bytes memory low) {
                    lastBuybackFailed = true; emit BuybackFailed(bnbForBurn); emit BuybackFailedDetailed(_getRevertMsg(low));
                }
            }

            // Add liquidity using reserved token-side and BNB
            if (bnbForLiquidity > 0) {
                if (tokensForLP > 0) {
                    _approve(address(this), address(pancakeRouter), tokensForLP);
                    try pancakeRouter.addLiquidityETH{ value: bnbForLiquidity }(address(this), tokensForLP, 0, 0, lpTokenRecipient, block.timestamp) returns (uint amountToken, uint amountETH, uint liquidity) {
                        emit LiquidityAdded(amountToken, amountETH, liquidity); lastLiquidityFailed = false;
                    } catch Error(string memory reason) {
                        lastLiquidityFailed = true; emit LiquidityFailed(bnbForLiquidity); emit LiquidityFailedDetailed(reason);
                    } catch (bytes memory low) {
                        lastLiquidityFailed = true; emit LiquidityFailed(bnbForLiquidity); emit LiquidityFailedDetailed(_getRevertMsg(low));
                    }
                } else {
                    pendingBuybackBNB += bnbForLiquidity; emit PendingBuybackUpdated(bnbForLiquidity);
                }
            }

            uint256 leftover = address(this).balance > bnbBeforeBuyback ? address(this).balance - bnbBeforeBuyback : 0;
            if (leftover > 0) { pendingBuybackBNB += leftover; emit PendingBuybackUpdated(leftover); }
        }

        emit SwapTokensForBNB(tokenAmount, bnbReceived);
        emit TaxDistributed(0, bnbToReserve, bnbToBuyback);
        return true;
    }

    // helper to decode revert reason from low-level catch
    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction reverted silently";
        bytes memory revertData = _returnData;
        assembly { revertData := add(revertData, 0x04) }
        return abi.decode(revertData, (string));
    }

    // Owner helper to trigger swapping accumulated tax tokens to BNB immediately
    function swapCollectedTaxesNow(uint256 amount) external onlyOwner lockTheSwap nonReentrant {
        if (amount == 0) return;
        uint256 available = balanceOf(address(this));
        uint256 toSwap = amount;
        if (toSwap > tokensForTax) toSwap = tokensForTax;
        if (toSwap > available) toSwap = available;
        if (toSwap == 0) return;
        bool swapped = _distributeTaxes(toSwap);
        if (swapped) {
            if (tokensForTax >= toSwap) tokensForTax -= toSwap; else tokensForTax = 0;
        }
    }

    // burn helpers
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
    function burnFrom(address account, uint256 amount) external { _approve(account, msg.sender, allowance(account, msg.sender) - amount); _burn(account, amount); }
}
