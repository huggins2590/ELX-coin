const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
    const [deployer, devWallet, u1, u2, u3, u4, u5] = await ethers.getSigners();
    const traders = [u1, u2, u3, u4, u5];
    
    const format = (v) => parseFloat(ethers.utils.formatEther(v)).toFixed(6);

    console.log("==========================================================");
    console.log("       ELX TOKEN - 2,000 TRANSACTION BATTLE TEST");
    console.log("==========================================================\n");

    // 1) Setup DEX environment (WBNB, Factory, Router)
    const WBNB = await ethers.getContractFactory("WBNB");
    const wbnb = await WBNB.deploy();
    const Factory = await ethers.getContractFactory("PancakeFactory");
    const factory = await Factory.deploy(deployer.address);
    const Router = await ethers.getContractFactory("PancakeRouter02");
    const router = await Router.deploy(factory.address, wbnb.address);

    // 2) Deploy ELX system and vaults
    const ELXToken = await ethers.getContractFactory("ELXToken");
    const elx = await ELXToken.deploy("ELX Token", "ELX", router.address, devWallet.address);
    const RewardsVault = await ethers.getContractFactory("RewardsVault");
    const rewardsVault = await RewardsVault.deploy(elx.address);
    const ReserveVault = await ethers.getContractFactory("ReserveVault");
    const reserveVault = await ReserveVault.deploy(elx.address, router.address);

    // 3) Add initial liquidity for stress test
    const tokensInPool = ethers.utils.parseEther("10000000"); // 10M
    const bnbInPool = ethers.utils.parseEther("1000"); // 1000 BNB
    await elx.approve(router.address, tokensInPool);
    await router.addLiquidityETH(elx.address, tokensInPool, 0, 0, deployer.address, 9999999999, { value: bnbInPool });

    // Now that pair exists, set vaults with the actual pair address
    const pairAddress = await factory.getPair(elx.address, wbnb.address);
    await elx.setVaults(reserveVault.address, rewardsVault.address, pairAddress);

    console.log("✓ System deployed and 1,000 BNB Liquidity added.\n");

    // Event listeners for swaps and distributions
    elx.on("SwapTokensForBNB", (tokens, bnb) => {
        if (bnb.gt(0)) {
            console.log(`\n[EVENT] *** AUTO-TAX SWAP SUCCESS ***`);
            console.log(`Tokens Swapped: ${format(tokens)} | BNB Received: ${format(bnb)}`);
        } else {
            console.log(`\n[EVENT] !!! AUTO-TAX SWAP FAILED/SKIPPED (0 BNB) !!!`);
        }
    });

    elx.on("TaxDistributed", (devTokens, bnbToReserve, bnbToBuyback) => {
        console.log(`[EVENT] Distribution: Reserve: +${format(bnbToReserve)} BNB | Buyback: +${format(bnbToBuyback)} BNB`);
    });

    // Run stress test loop of randomized trades
    const TOTAL_TX = 2000;
    let successfulTrades = 0;
    let failedTrades = 0;
    let failureReasons = {};

    console.log("✓ Initializing traders with first buys...");
    for (const trader of traders) {
        await router.connect(trader).swapExactETHForTokensSupportingFeeOnTransferTokens(
            0, [wbnb.address, elx.address], trader.address, 9999999999, { value: ethers.utils.parseEther("1") }
        );
    }
    console.log("✓ Traders ready.\n");

    console.log(`Starting ${TOTAL_TX} random trades... (Buys, Sells, Whale trades, Dust trades)`);

    for (let i = 1; i <= TOTAL_TX; i++) {
        const actor = traders[Math.floor(Math.random() * traders.length)];
        const isBuy = Math.random() > 0.5;
        let logMsg = "";
        
        try {
            if (isBuy) {
                // Mix of Small (no trigger) and Large (trigger) buys
                const isSmall = Math.random() > 0.8; 
                const amountBNB = isSmall 
                    ? ethers.utils.parseEther("0.0001") // Tiny buy, 5% tax < 1000 tokens
                    : ethers.utils.parseEther((Math.random() * 5 + 0.1).toFixed(4)); 
                
                const balBefore = await elx.balanceOf(actor.address);
                await router.connect(actor).swapExactETHForTokensSupportingFeeOnTransferTokens(
                    0, [wbnb.address, elx.address], actor.address, 9999999999, { value: amountBNB }
                );
                const balAfter = await elx.balanceOf(actor.address);
                logMsg = `[TX ${i}] BUY  | BNB: ${format(amountBNB).padStart(8)} | ELX Recv: ${format(balAfter.sub(balBefore)).padStart(10)}`;
            } else {
                const bal = await elx.balanceOf(actor.address);
                if (bal.gt(0)) {
                    const sellAmount = bal.div(Math.floor(Math.random() * 10) + 2); 
                    await elx.connect(actor).approve(router.address, sellAmount);
                    await router.connect(actor).swapExactTokensForETHSupportingFeeOnTransferTokens(
                        sellAmount, 0, [elx.address, wbnb.address], actor.address, 9999999999
                    );
                    logMsg = `[TX ${i}] SELL | ELX: ${format(sellAmount).padStart(8)} | BNB Recv: ...`;
                } else {
                    logMsg = `[TX ${i}] SKIP | No balance for trader`;
                }
            }
            successfulTrades++;
        } catch (err) {
            failedTrades++;
            const reason = err.message.split(":")[0] || "Unknown Error";
            failureReasons[reason] = (failureReasons[reason] || 0) + 1;
            logMsg = `[TX ${i}] FAIL | ${reason.substring(0, 30)}`;
        }

        // Detailed balance logging after EVERY trade
        const rewBal = await elx.balanceOf(rewardsVault.address);
        const resBal = await ethers.provider.getBalance(reserveVault.address);
        const conTax = await elx.tokensAccumulatedForTax();

        console.log(`${logMsg} | Rewards: ${format(rewBal).padStart(8)} | Reserve: ${format(resBal).padStart(8)} | PendingTax: ${format(conTax).padStart(8)}`);
    }

    console.log("\n\n==========================================");
    console.log("         FINAL SYSTEM AUDIT");
    console.log("==========================================");
    
    console.log(`Successful Trades: ${successfulTrades}`);
    console.log(`Failed Trades:     ${failedTrades}`);
    
    if (failedTrades > 0) {
        console.log("\n--- Failure Reasons Summary ---");
        for (const [reason, count] of Object.entries(failureReasons)) {
            console.log(`> ${reason}: ${count} occurrences`);
        }
    }
    
    console.log("------------------------------------------");
    console.log(`Rewards Vault ELX: ${format(await elx.balanceOf(rewardsVault.address))}`);
    console.log(`Reserve Vault BNB: ${format(await ethers.provider.getBalance(reserveVault.address))}`);
    console.log(`Burn Address ELX:  ${format(await elx.balanceOf("0x000000000000000000000000000000000000dEaD"))}`);
    console.log(`Dev Wallet ELX:    ${format(await elx.balanceOf(devWallet.address))}`);
    console.log(`ELX Contract BNB:  ${format(await ethers.provider.getBalance(elx.address))}`);
    console.log(`ELX Contract ELX:  ${format(await elx.balanceOf(elx.address))}`);
    console.log("==========================================\n");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
