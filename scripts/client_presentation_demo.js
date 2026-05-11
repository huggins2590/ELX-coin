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

    // Setup Pair & Link Vaults (3-argument setVaults)
    await factory.createPair(testToken.address, wbnb.address);
    const pairAddress = await factory.getPair(testToken.address, wbnb.address);
    await testToken.setVaults(reserveVault.address, rewardsVault.address, pairAddress);
    console.log(`✓ Vaults & Pair linked to token contract.`);

    // Add Liquidity (1M ELX + 100 BNB)
    const tokensToAdd = ethers.utils.parseEther("1000000");
    const bnbToAdd = ethers.utils.parseEther("100");
    await testToken.approve(router.address, tokensToAdd);
    await router.addLiquidityETH(
        testToken.address,
        tokensToAdd,
        0, 0,
        deployer.address,
        ethers.constants.MaxUint256,
        { value: bnbToAdd }
    );
    console.log(`✓ Initial Liquidity Added: 1M ELX + 100 BNB\n`);

    const format = (bn) => parseFloat(ethers.utils.formatEther(bn)).toFixed(4);
    
    console.log("==========================================================");
    console.log("STEP 2: TRADING & TAX DISTRIBUTION");
    console.log("==========================================================");
    console.log("Scenario: User buys tokens. Tax is collected and immediately processed on the next Sell.");
    
    // User1 Buys 30 BNB worth
    await router.connect(buyer1).swapExactETHForTokensSupportingFeeOnTransferTokens(0, [wbnb.address, testToken.address], buyer1.address, ethers.constants.MaxUint256, {value: ethers.utils.parseEther("30")});
    console.log(`\n✓ Buyer 1 bought tokens (Price Up!). Tax is accumulated in ELX contract.`);

    const reserveBalBefore = await ethers.provider.getBalance(reserveVault.address);

    console.log("\n> Buyer 1 sells a tiny portion. This 'flushes' the accumulated Buy tax into the vaults.");
    const flushAmt = ethers.utils.parseEther("1000");
    await testToken.connect(buyer1).approve(router.address, flushAmt);
    await router.connect(buyer1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        flushAmt, 0, [testToken.address, wbnb.address], buyer1.address, ethers.constants.MaxUint256
    );

    const reserveBalAfter = await ethers.provider.getBalance(reserveVault.address);
    console.log(`✓ Tax Flush Complete. Reserve Vault received: ${format(reserveBalAfter.sub(reserveBalBefore))} BNB`);
    
    console.log("\n==========================================================");
    console.log("STEP 3: SMART RESERVE BUYBACK (PRICE SUPPORT)");
    console.log("==========================================================");
    console.log("Scenario: Heavy sell pressure is detected. System fires an ATOMIC buyback + burn.");

    // Fund Reserve Vault manually for demo
    await deployer.sendTransaction({ to: reserveVault.address, value: ethers.utils.parseEther("10") });
    console.log(`✓ Reserve Vault funded with 10 BNB for demonstration.`);

    const sellAmountHuge = ethers.utils.parseEther("10000000"); // 10M ELX (> 0.5% threshold)
    await testToken.connect(deployer).transfer(buyer2.address, sellAmountHuge);
    await testToken.connect(buyer2).approve(router.address, ethers.constants.MaxUint256);

    const deadAddress = "0x000000000000000000000000000000000000dEaD";
    const burnedBefore = await testToken.balanceOf(deadAddress);

    console.log(`\n> Buyer 2 panic sells ${format(sellAmountHuge)} ELX!`);
    await router.connect(buyer2).swapExactTokensForETHSupportingFeeOnTransferTokens(
        sellAmountHuge, 0, [testToken.address, wbnb.address], buyer2.address, ethers.constants.MaxUint256
    );

    const burnedAfter = await testToken.balanceOf(deadAddress);
    console.log(`\n✓ Sell pressure detected AND neutralized ATOMICALLY!`);
    console.log(`✓ ELX Tokens Burned in the SAME transaction: ${format(burnedAfter.sub(burnedBefore))} ELX`);


    console.log("\n==========================================================");
    console.log("STEP 4: REWARDS SYSTEM (LOYALTY CLAIM)");
    console.log("==========================================================");
    
    console.log(`\n> Fast-forwarding time by 72 hours...`);
    await network.provider.send("evm_increaseTime", [72 * 3600 + 3600]);
    await network.provider.send("evm_mine");

    const claimAmountB1 = await rewardsVault.getClaimableAmount(buyer1.address);
    console.log(`Buyer 1 is eligible to claim: ${format(claimAmountB1)} ELX`);

    const b1BalBefore = await testToken.balanceOf(buyer1.address);
    await rewardsVault.connect(buyer1).claimReward();
    const b1BalAfter = await testToken.balanceOf(buyer1.address);
    
    console.log(`\n✓ Buyer 1 claimed rewards! (+${format(b1BalAfter.sub(b1BalBefore))} ELX)`);

    console.log("\n==========================================================");
    console.log("                 DEMONSTRATION COMPLETE");
    console.log("==========================================================");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
