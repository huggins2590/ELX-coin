const { ethers } = require("hardhat");

async function main() {
  // Let's get our accounts first
  const [deployer, devWallet] = await ethers.getSigners();
  console.log("Starting deployment using account:", deployer.address);
  console.log("Dev wallet is set to:", devWallet.address);

  // First, we'll deploy the main ELX Token contract
  // We're passing the Zero address for the router in the constructor for now
  console.log("\nDeploying the ELX Token...");
  const ELXToken = await ethers.getContractFactory("ELXToken");
  const elx = await ELXToken.deploy(
    "ELX Token",
    "ELX",
    ethers.constants.AddressZero, // Router address set to 0
    devWallet.address
  );
  await elx.deployed();
  console.log("✓ ELX Token is live at:", elx.address);

  // Now we deploy the Reserve Vault, which needs the token address
  console.log("Deploying the Reserve Vault...");
  const ReserveVault = await ethers.getContractFactory("ReserveVault");
  const reserve = await ReserveVault.deploy(elx.address);
  await reserve.deployed();
  console.log("✓ Reserve Vault is live at:", reserve.address);

  // Next is the Rewards Vault, also needing the token address
  console.log("Deploying the Rewards Vault...");
  const RewardsVault = await ethers.getContractFactory("RewardsVault");
  const rewards = await RewardsVault.deploy(elx.address);
  await rewards.deployed();
  console.log("✓ Rewards Vault is live at:", rewards.address);

  // Finally, we need to link the vaults back to the token so the taxes go to the right place
  console.log("Connecting the vaults to the token...");
  const tx = await elx.setVaults(reserve.address, rewards.address);
  await tx.wait();
  console.log("✓ Vaults successfully linked to ELX Token.");

  console.log("\nAll done! Your contracts are deployed and connected.");
}

main().catch((error) => {
  console.error("Oops! Something went wrong during deployment:", error);
  process.exitCode = 1;
});





