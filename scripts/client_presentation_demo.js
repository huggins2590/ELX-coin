const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
    const [deployer, buyer1, buyer2, buyer3, devWallet] = await ethers.getSigners();

    console.log("==========================================================");
    console.log("       ELX TOKEN - FULL SYSTEM DEMONSTRATION");
    console.log("==========================================================\n");

    console.log("STEP 1: DEPLOYMENT & SETUP");
    console.log("----------------------------------------------------------");
    
    // Deploy WBNB
    const WBNB = await ethers.getContractFactory("WBNB");
    const wbnb = await WBNB.deploy();
    await wbnb.deployed();

    // Deploy Factory
    const PancakeFactory = await ethers.getContractFactory("PancakeFactory");
    const factory = await PancakeFactory.deploy(deployer.address);
    await factory.deployed();

    // Deploy Mock Router
    const PancakeRouterMock = await ethers.getContractFactory("PancakeRouter02");
    const router = await PancakeRouterMock.deploy(factory.address, wbnb.address);
    await router.deployed();
    console.log(`✓ Router deployed at: ${router.address}`);

    // Deploy ELX Token
    const ELXToken = await ethers.getContractFactory("ELXToken");
    const testToken = await ELXToken.deploy("ELX Token", "ELX", router.address, devWallet.address);
    await testToken.deployed();
    console.log(`✓ ELX Token deployed at: ${testToken.address}`);

    // Deploy Vaults
    const RewardsVault = await ethers.getContractFactory("RewardsVault");
    const rewardsVault = await RewardsVault.deploy(testToken.address);
    await rewardsVault.deployed();
    console.log(`✓ Rewards Vault deployed at: ${rewardsVault.address}`);

    const ReserveVault = await ethers.getContractFactory("ReserveVault");
    const reserveVault = await ReserveVault.deploy(testToken.address, router.address);
    await reserveVault.deployed();
    console.log(`✓ Reserve Vault deployed at: ${reserveVault.address}`);

    // Link Vaults to Token
    await testToken.setVaults(reserveVault.address, rewardsVault.address);
    console.log(`✓ Vaults linked to token contract.`);

    // Lower reward threshold for the demo (5k ELX instead of 50k)
    await testToken.setRewardThreshold(ethers.utils.parseEther("5000"));
    console.log(`✓ Reward Threshold lowered to 5k ELX for demonstration.`);

    // Add Liquidity (100k ELX + 10 BNB)
    const tokensToAdd = ethers.utils.parseEther("100000");
    const bnbToAdd = ethers.utils.parseEther("10");
    await testToken.approve(router.address, tokensToAdd);
    await router.addLiquidityETH(
        testToken.address,
        tokensToAdd,
        0, 0,
        deployer.address,
        Date.now() + 1000,
        { value: bnbToAdd }
    );
    console.log(`✓ Initial Liquidity Added: 100k ELX + 10 BNB\n`);

    // Helper functions
    const format = (bn) => parseFloat(ethers.utils.formatEther(bn)).toFixed(4);
    const logBalances = async (title) => {
        console.log(`\n--- ${title} ---`);
        console.log(`Dev Wallet (ELX): ${format(await testToken.balanceOf(devWallet.address))}`);
        console.log(`Rewards Vault (ELX): ${format(await testToken.balanceOf(rewardsVault.address))}`);
        console.log(`Reserve Vault (BNB): ${format(await ethers.provider.getBalance(reserveVault.address))}`);
        console.log(`ELX Contract (BNB): ${format(await ethers.provider.getBalance(testToken.address))} | (ELX): ${format(await testToken.balanceOf(testToken.address))}`);
        console.log(`  (Note: The ELX contract holds tokens/BNB for its built-in continuous buybacks)`);
    };

    console.log("==========================================================");
    console.log("STEP 2: TRADING & TAX DISTRIBUTION");
    console.log("==========================================================");
    console.log("Scenario: Users buy tokens, then a user sells, triggering the 5% tax.");
    
    // Buys (to give users tokens to play with)
    await router.connect(buyer1).swapExactETHForTokensSupportingFeeOnTransferTokens(0, [await router.WETH(), testToken.address], buyer1.address, Date.now() + 1000, {value: ethers.utils.parseEther("1")});
    await router.connect(buyer2).swapExactETHForTokensSupportingFeeOnTransferTokens(0, [await router.WETH(), testToken.address], buyer2.address, Date.now() + 1000, {value: ethers.utils.parseEther("1")});
    await router.connect(buyer3).swapExactETHForTokensSupportingFeeOnTransferTokens(0, [await router.WETH(), testToken.address], buyer3.address, Date.now() + 1000, {value: ethers.utils.parseEther("1")});
    
    console.log(`\n✓ Users 1, 2, and 3 bought tokens.`);
    
    await logBalances("Balances Before Tax Distribution Swap");

    // Set threshold very high so it doesn't auto-swap during the sell
    await testToken.setSwapTokensAtAmount(ethers.utils.parseEther("1000000")); 
    
    console.log("\n> Buyer 1 sells tokens. The contract collects a 5% tax in ELX.");
    
    const b1Bal = await testToken.balanceOf(buyer1.address);
    const sellAmount = b1Bal.div(2);
    await testToken.connect(buyer1).approve(router.address, sellAmount);
    await router.connect(buyer1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        sellAmount, 0, [testToken.address, await router.WETH()], buyer1.address, Date.now() + 1000
    );

    console.log("\n> Now we manually trigger the Tax Swap. The contract sells the collected ELX for BNB, funding the Reserve Vault.");
    const taxTokens = await testToken.tokensAccumulatedForTax();
    await testToken.swapCollectedTaxesNow(taxTokens);

    await logBalances("Balances After Sell & Tax Distribution");


    console.log("\n==========================================================");
    console.log("STEP 3: REWARDS SYSTEM (LOYALTY CLAIM)");
    console.log("==========================================================");
    console.log("Scenario: 72 hours pass. Loyal holders can now claim their share of the Rewards Vault.");

    console.log(`\n> Fast-forwarding time by 72 hours...`);
    await ethers.provider.send("evm_increaseTime", [72 * 60 * 60 + 1]);
    await ethers.provider.send("evm_mine");

    const claimAmountB2 = format(await rewardsVault.getClaimableAmount(buyer2.address));
    const claimAmountB3 = format(await rewardsVault.getClaimableAmount(buyer3.address));
    
    console.log(`\nBuyer 2 is eligible to claim: ${claimAmountB2} ELX`);
    console.log(`Buyer 3 is eligible to claim: ${claimAmountB3} ELX`);

    const b2BalBefore = await testToken.balanceOf(buyer2.address);
    await rewardsVault.connect(buyer2).claimReward();
    const b2BalAfter = await testToken.balanceOf(buyer2.address);
    
    console.log(`\n✓ Buyer 2 claimed rewards!`);
    console.log(`  Buyer 2 Balance Before: ${format(b2BalBefore)} ELX`);
    console.log(`  Buyer 2 Balance After:  ${format(b2BalAfter)} ELX (+${format(b2BalAfter.sub(b2BalBefore))})`);


    console.log("\n==========================================================");
    console.log("STEP 4: SMART RESERVE BUYBACK (PRICE SUPPORT)");
    console.log("==========================================================");
    console.log("Scenario: Sell pressure spikes. The contract uses Reserve BNB to automatically buy and burn ELX.");

    // Instead of manual funding, we'll simulate more trades to fund the vaults naturally.
    console.log(`\n> Simulating high volume to fund the Reserve Vault naturally via taxes...`);
    for(let i=0; i<3; i++) {
        // Buy a lot of tokens
        await router.connect(buyer1).swapExactETHForTokensSupportingFeeOnTransferTokens(0, [await router.WETH(), testToken.address], buyer1.address, Date.now() + 1000, {value: ethers.utils.parseEther("5")});
        
        // Sell half of them
        const b1Bal = await testToken.balanceOf(buyer1.address);
        const sellHalf = b1Bal.div(2);
        await testToken.connect(buyer1).approve(router.address, sellHalf);
        await router.connect(buyer1).swapExactTokensForETHSupportingFeeOnTransferTokens(sellHalf, 0, [testToken.address, await router.WETH()], buyer1.address, Date.now() + 1000);
    }
    
    // Trigger the tax swap to move BNB to Reserve Vault
    const currentTax = await testToken.tokensAccumulatedForTax();
    await testToken.swapCollectedTaxesNow(currentTax);

    // Set a very low minimum for the demo so it triggers
    await reserveVault.setMinBuybackAmount(ethers.utils.parseEther("0.001"));
    console.log(`✓ Reserve Vault funded via taxes. Minimum buyback threshold set to 0.001 BNB for demo.`);

    // Lower threshold to 1 bps (100,000 ELX)
    await testToken.setSellPressureThreshold(1); 
    console.log(`> Lowered sell pressure threshold to 1 bps (100,000 ELX) for testing.\n`);

    const sellAmountHuge = ethers.utils.parseEther("150000"); // 150k ELX
    
    console.log(`> Deployer transfers 150k ELX to Buyer 1 so they can trigger the threshold...`);
    await testToken.connect(deployer).transfer(buyer1.address, sellAmountHuge);

    console.log(`> Buyer 1 panic sells ${format(sellAmountHuge)} ELX! This exceeds the threshold.`);
    await testToken.connect(buyer1).approve(router.address, sellAmountHuge);
    await router.connect(buyer1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        sellAmountHuge, 0, [testToken.address, await router.WETH()], buyer1.address, Date.now() + 1000
    );

    const isPending = await testToken.buybackPending();
    console.log(`\n✓ Sell pressure detected!`);
    console.log(`✓ buybackPending flag is now: ${isPending} (Waiting for next safe transaction)`);

    const deadAddress = "0x000000000000000000000000000000000000dEaD";
    const burnedBefore = await testToken.balanceOf(deadAddress);
    const vaultBnbBefore = await ethers.provider.getBalance(reserveVault.address);

    console.log(`\n> A normal transfer happens on the network, triggering the pending buyback...`);
    // Regular transfer triggers the pending buyback
    await testToken.connect(buyer2).transfer(buyer3.address, ethers.utils.parseEther("1"));

    const burnedAfter = await testToken.balanceOf(deadAddress);
    const vaultBnbAfter = await ethers.provider.getBalance(reserveVault.address);

    console.log(`\n✓ Buyback Executed Successfully!`);
    console.log(`  BNB Spent from Vault: ${format(vaultBnbBefore.sub(vaultBnbAfter))} BNB`);
    console.log(`  ELX Tokens Burned:    ${format(burnedAfter.sub(burnedBefore))} ELX`);

    console.log("\n==========================================================");
    console.log("                 DEMONSTRATION COMPLETE");
    console.log("==========================================================");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
