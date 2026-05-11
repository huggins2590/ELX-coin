const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
    const [deployer, whale, user1, user2, user3, devWallet] = await ethers.getSigners();
    const format = (bn) => parseFloat(ethers.utils.formatEther(bn)).toLocaleString(undefined, {maximumFractionDigits: 3});

    console.log("\n===================================================================");
    console.log("       ELX TOKEN: ULTIMATE MAINNET FORK SIMULATION");
    console.log("===================================================================\n");

    const PANCAKE_ROUTER = "0x10ED43C718714eb63d5aA57B78B54704E256024E";
    const DEAD_ADDRESS = "0x000000000000000000000000000000000000dEaD";
    
    // --- 1. DEPLOYMENT ---
    console.log("[1] Deploying Contracts to BSC Mainnet Fork...");
    const ELXToken = await ethers.getContractFactory("ELXToken");
    const token = await ELXToken.deploy("ELX Token", "ELX", PANCAKE_ROUTER, devWallet.address);
    await token.deployed();
    
    const ReserveVault = await ethers.getContractFactory("ReserveVault");
    const reserveVault = await ReserveVault.deploy(token.address, PANCAKE_ROUTER);
    await reserveVault.deployed();

    const RewardsVault = await ethers.getContractFactory("RewardsVault");
    const rewardsVault = await RewardsVault.deploy(token.address);
    await rewardsVault.deployed();

    const router = await ethers.getContractAt("contracts/ELXToken.sol:IUniswapV2Router02", PANCAKE_ROUTER);
    const wbnbAddress = await router.WETH();
    const factoryAddress = await router.factory();
    const factory = await ethers.getContractAt("contracts/ELXToken.sol:IPancakeSwapV2Factory", factoryAddress);

    // --- 2. INITIAL LIQUIDITY SETUP (40k Market Cap) ---
    console.log("\n[2] Setting up $40k Market Cap Liquidity...");
    const bnbInLP = ethers.utils.parseEther("66.666"); // ~$40,000 at $600/BNB
    const tokensInLP = ethers.utils.parseEther("600000000"); // 600M Circulating Supply
    
    await token.approve(PANCAKE_ROUTER, tokensInLP);
    await router.addLiquidityETH(
        token.address, tokensInLP, 0, 0, deployer.address, 9999999999, { value: bnbInLP }
    );
    const pairAddress = await factory.getPair(token.address, wbnbAddress);
    console.log(`    ✓ Added ${format(bnbInLP)} BNB and ${format(tokensInLP)} ELX to PancakeSwap.`);
    console.log(`    ✓ Pair Address: ${pairAddress}`);

    await token.setVaults(reserveVault.address, rewardsVault.address, pairAddress);
    console.log(`    ✓ Vaults and Pair linked.`);

    // (Whale will acquire tokens through buying later in the script)

    // --- STATE TRACKING UTILITIES ---
    let lastBurned = ethers.BigNumber.from(0);
    const threshold = (await token.totalSupply()).mul(await token.SELL_PRESSURE_THRESHOLD_BPS()).div(10000);

    const getSystemState = async (label) => {
        const vaultState = await reserveVault.getVaultState();
        let pricePerMillion = [0, 0];
        try {
            pricePerMillion = await router.getAmountsOut(ethers.utils.parseEther("1000000"), [token.address, wbnbAddress]);
        } catch(e) {}
        
        const volume = await token.getSellVolumeLastHour();
        const pendingTax = await token.tokensAccumulatedForTax();
        const totalBurned = await token.balanceOf(DEAD_ADDRESS);
        const burnedSinceLast = totalBurned.sub(lastBurned);
        lastBurned = totalBurned;

        const devBal = await ethers.provider.getBalance(devWallet.address);

        console.log(`\n=================== ${label} ===================`);
        console.log(` Price (1M ELX):      ${format(pricePerMillion[1] || 0)} BNB`);
        console.log(` 1H Sell Volume:      ${format(volume)} / ${format(threshold)} ELX`);
        console.log(` Tax Queue:           ${format(pendingTax)} / 10,000 ELX`);
        console.log(` Reserve Vault BNB:   ${format(vaultState.balance)} BNB (Ready: ${vaultState.ready})`);
        console.log(` Eligible Holders:    ${await token.eligibleHoldersCount()}`);
        console.log(` Tokens Burned:       +${format(burnedSinceLast)} ELX (Total: ${format(totalBurned)})`);
        console.log(` Dev Wallet BNB:      ${format(devBal)} BNB`);
        console.log(`-----------------------------------------------------------------`);
    };

    await getSystemState("INITIAL STATE (POST-LIQUIDITY)");

    // --- 3. RETAIL BUYING ACTIVITY ---
    console.log("\n[3] Simulating Retail Buying (Users entering ecosystem)...");
    console.log("    > User1 buys 0.5 BNB");
    await router.connect(user1).swapExactETHForTokensSupportingFeeOnTransferTokens(
        0, [wbnbAddress, token.address], user1.address, 9999999999, { value: ethers.utils.parseEther("0.5") }
    );
    console.log("    > User2 buys 0.5 BNB");
    await router.connect(user2).swapExactETHForTokensSupportingFeeOnTransferTokens(
        0, [wbnbAddress, token.address], user2.address, 9999999999, { value: ethers.utils.parseEther("0.5") }
    );
    console.log("    > User3 buys 0.5 BNB");
    await router.connect(user3).swapExactETHForTokensSupportingFeeOnTransferTokens(
        0, [wbnbAddress, token.address], user3.address, 9999999999, { value: ethers.utils.parseEther("0.5") }
    );
    await getSystemState("AFTER RETAIL BUYS (TAXES COLLECTED)");

    // --- 4. CONTINUOUS TAX SWAP (AUTOMATED) ---
    console.log("\n[4] Triggering Continuous Tax Swap...");
    console.log("    > The Tax Queue should be over 10,000 ELX now.");
    console.log("    > Next tiny sell will process the tax swap.");
    await token.connect(user1).approve(PANCAKE_ROUTER, ethers.constants.MaxUint256);
    await router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        ethers.utils.parseEther("100"), 0, [token.address, wbnbAddress], user1.address, 9999999999
    );
    await getSystemState("AFTER CONTINUOUS TAX SWAP (RESERVE FUNDED, ELX BURNED)");

    // --- 5. WHALE ACCUMULATION ---
    console.log("\n[5] Whale Accumulation (Massive Buy)...");
    console.log("    > Whale buys 10 BNB worth of ELX");
    await router.connect(whale).swapExactETHForTokensSupportingFeeOnTransferTokens(
        0, [wbnbAddress, token.address], whale.address, 9999999999, { value: ethers.utils.parseEther("10") }
    );
    await getSystemState("AFTER WHALE BUY (PRICE SURGE)");

    // --- 6. REGULAR TRANSFER (NO TAX) ---
    console.log("\n[6] Regular Wallet-to-Wallet Transfer...");
    const user1BalBefore = await token.balanceOf(user1.address);
    console.log("    > User1 sends 1,000 ELX to User2");
    await token.connect(user1).transfer(user2.address, ethers.utils.parseEther("1000"));
    const user1BalAfter = await token.balanceOf(user1.address);
    console.log(`    > User1 actually lost: ${format(user1BalBefore.sub(user1BalAfter))} ELX`);
    await getSystemState("AFTER REGULAR TRANSFER (NO TRIGGER CHECK)");

    // --- 7. WHALE DUMP & RESERVE TRIGGER ---
    console.log("\n[7] Whale Dump (Crossing 0.5% Sell Pressure Threshold)...");
    console.log("    > Whale sells 15,000,000 ELX");
    console.log("    > The Reserve Buyback will be ready after this sell.");
    const sellAmount = ethers.utils.parseEther("15000000");
    await token.connect(whale).approve(PANCAKE_ROUTER, sellAmount);
    await router.connect(whale).swapExactTokensForETHSupportingFeeOnTransferTokens(
        sellAmount, 0, [token.address, wbnbAddress], whale.address, 9999999999
    );
    await getSystemState("AFTER WHALE DUMP (RESERVE READY)");

    // --- 8. SMART RESERVE EXECUTION ---
    console.log("\n[8] Executing Smart Reserve Buyback...");
    console.log("    > The next SELL will fire the reserve (Priority #1).");
    await router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        ethers.utils.parseEther("100"), 0, [token.address, wbnbAddress], user1.address, 9999999999
    );
    await getSystemState("AFTER SMART RESERVE EXECUTION (MASSIVE BURN)");

    // --- 9. COOLDOWN PROTECTION ---
    console.log("\n[9] Cooldown Guard Test...");
    console.log("    > Whale immediately tries to dump another 10,000,000 ELX");
    const sellAmount2 = ethers.utils.parseEther("10000000");
    await token.connect(whale).approve(PANCAKE_ROUTER, sellAmount2);
    await router.connect(whale).swapExactTokensForETHSupportingFeeOnTransferTokens(
        sellAmount2, 0, [token.address, wbnbAddress], whale.address, 9999999999
    );
    console.log("    > Doing a normal transfer to attempt trigger...");
    await token.connect(user1).transfer(user2.address, 100);
    await getSystemState("AFTER 2ND DUMP (IGNORED DUE TO 4-HOUR COOLDOWN)");

    // --- 10. REWARD ELIGIBILITY & FAST FORWARD ---
    console.log("\n[10] Fast-Forwarding 73 Hours for Reward Claims...");
    await ethers.provider.send("evm_increaseTime", [73 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    console.log("    > User2 (Held Tokens) Attempts Claim...");
    const claimableUser2 = await rewardsVault.getClaimableAmount(user2.address);
    console.log(`      User2 can claim: ${format(claimableUser2)} ELX`);
    if(claimableUser2.gt(0)) {
        await rewardsVault.connect(user2).claimReward();
        console.log(`      ✓ Claim successful!`);
    }

    console.log("    > Whale (Sold Tokens recently) Attempts Claim...");
    const claimableWhale = await rewardsVault.getClaimableAmount(whale.address);
    console.log(`      Whale can claim: ${format(claimableWhale)} ELX`);
    if(claimableWhale.gt(0)) {
        await rewardsVault.connect(whale).claimReward();
    } else {
        console.log(`      ✗ Whale is ineligible (Did not meet holding requirements).`);
    }

    await getSystemState("FINAL SYSTEM STATUS (73 HOURS LATER)");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
