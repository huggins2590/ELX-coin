const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
    console.log("ELX DEPLOYMENT SCRIPT");

    const [deployer, devWallet] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);
    console.log("Dev Wallet:", devWallet.address, "\n");

    
    // STEP 1: Deploy empty mock ReserveVault and RewardsVault 
    console.log("STEP 1: Deploying ReserveVault and RewardsVault...");
    const ReserveVault = await ethers.getContractFactory("ReserveVault");
    const reserveVault = await ReserveVault.deploy();
    await reserveVault.deployed();
    console.log("✓ ReserveVault deployed at:", reserveVault.address);

    const RewardsVault = await ethers.getContractFactory("RewardsVault");
    const rewardsVault = await RewardsVault.deploy();
    await rewardsVault.deployed();
    console.log("✓ RewardsVault deployed at:", rewardsVault.address, "\n");

    //  STEP 2: Deploy ELXToken 
    console.log("STEP 2: Deploying ELXToken (1B supply)...");
    const ELXToken = await ethers.getContractFactory("ELXToken");
    // New constructor: (name, symbol, routerAddress, devWallet, reserveVault, rewardsVault)
    const elxToken = await ELXToken.deploy(
        "ELX Token",
        "ELX",
        ethers.constants.AddressZero, // No router for now
        devWallet.address,
        reserveVault.address,
        rewardsVault.address
    );
    await elxToken.deployed();
    console.log("✓ ELXToken deployed at:", elxToken.address, "\n");

    // ====== Display Initial Balances ======
    console.log("INITIAL BALANCES");
    let deployerBalance = await deployer.getBalance();
   
    console.log("Deployer BNB:", ethers.utils.formatEther(deployerBalance));
   
    let deployerTokenBalance = await elxToken.balanceOf(deployer.address);
    console.log("Deployer ELXToken:", ethers.utils.formatEther(deployerTokenBalance), "\n");

}

main().catch((error) => {
    console.error("ERROR:", error);
    process.exitCode = 1;
});
