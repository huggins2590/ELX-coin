const { expect } = require("chai");
const { ethers, network } = require("hardhat");

describe("ELX System Full Coverage", function () {
    let deployer, devWallet, user1, user2, user3;
    let wbnb, factory, router, elx, reserveVault, rewardsVault, pair;
    const BURN_ADDRESS = "0x000000000000000000000000000000000000dEaD";

    before(async function () {
        [deployer, devWallet, user1, user2, user3] = await ethers.getSigners();

        const WBNB = await ethers.getContractFactory("WBNB");
        wbnb = await WBNB.deploy();
        await wbnb.deployed();

        const Factory = await ethers.getContractFactory("PancakeFactory");
        factory = await Factory.deploy(deployer.address);
        await factory.deployed();

        const Router = await ethers.getContractFactory("PancakeRouter02");
        router = await Router.deploy(factory.address, wbnb.address);
        await router.deployed();

        const ELXToken = await ethers.getContractFactory("ELXToken");
        elx = await ELXToken.deploy("ELX Token", "ELX", router.address, devWallet.address);
        await elx.deployed();

        const RewardsVault = await ethers.getContractFactory("RewardsVault");
        rewardsVault = await RewardsVault.deploy(elx.address);
        await rewardsVault.deployed();

        const ReserveVault = await ethers.getContractFactory("ReserveVault");
        reserveVault = await ReserveVault.deploy(elx.address, router.address);
        await reserveVault.deployed();

        await factory.createPair(elx.address, wbnb.address);
        const pairAddress = await factory.getPair(elx.address, wbnb.address);
        
        await elx.setVaults(reserveVault.address, rewardsVault.address, pairAddress);
        
        const tokensToAdd = ethers.utils.parseEther("100000000"); 
        const bnbToAdd = ethers.utils.parseEther("1000"); 
        await elx.approve(router.address, tokensToAdd);
        await router.addLiquidityETH(
            elx.address,
            tokensToAdd,
            0, 0,
            deployer.address,
            ethers.constants.MaxUint256,
            { value: bnbToAdd }
        );

        await elx.transfer(user1.address, ethers.utils.parseEther("10000000"));
        await elx.transfer(user2.address, ethers.utils.parseEther("10000000"));
        await elx.transfer(user3.address, ethers.utils.parseEther("10000000"));
    });

    describe("1. ELX Token Core Mechanics", function () {
        it("Should execute normal transfers without tax", async function () {
            const amount = ethers.utils.parseEther("1000");
            const b2Before = await elx.balanceOf(user2.address);
            await elx.connect(user1).transfer(user2.address, amount);
            const b2After = await elx.balanceOf(user2.address);
            expect(b2After.sub(b2Before).eq(amount)).to.be.true;
        });


        it("Should collect tax on buys", async function () {
            const taxBefore = await elx.tokensAccumulatedForTax();
            await router.connect(user3).swapExactETHForTokensSupportingFeeOnTransferTokens(
                0, [wbnb.address, elx.address], user3.address, ethers.constants.MaxUint256, { value: ethers.utils.parseEther("1") }
            );
            const taxAfter = await elx.tokensAccumulatedForTax();
            expect(taxAfter.gt(taxBefore)).to.be.true;
        });

        it("Should collect tax on sells", async function () {
            const taxBefore = await elx.tokensAccumulatedForTax();
            const sellAmt = ethers.utils.parseEther("1000");
            await elx.connect(user3).approve(router.address, sellAmt);
            await router.connect(user3).swapExactTokensForETHSupportingFeeOnTransferTokens(
                sellAmt, 0, [elx.address, wbnb.address], user3.address, ethers.constants.MaxUint256
            );
            const taxAfter = await elx.tokensAccumulatedForTax();
            expect(taxAfter.gt(taxBefore)).to.be.true;
        });

        it("Should process tax swap atomically on Sell when queue > 10,000", async function () {
            const sellAmt = ethers.utils.parseEther("300000"); 
            const stateBefore = await reserveVault.getVaultState();
            
            await elx.connect(user1).approve(router.address, sellAmt);
            await router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
                sellAmt, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
            );

            const stateAfter = await reserveVault.getVaultState();
            expect(stateAfter.balance.gt(stateBefore.balance)).to.be.true;
        });
    });

    describe("2. Rewards Vault Mechanics", function () {
        it("Should track total tokens received automatically", async function () {
            const amount = ethers.utils.parseEther("100");
            const receivedBefore = await rewardsVault.totalTokensReceived();
            await elx.transfer(rewardsVault.address, amount);
            const receivedAfter = await rewardsVault.totalTokensReceived();
            expect(receivedAfter.sub(receivedBefore).eq(amount)).to.be.true;
        });

        it("Should not allow claims before 72 hours", async function () {
            try {
                await rewardsVault.connect(user1).claimReward();
                expect.fail("Should have reverted");
            } catch (e) {
                expect(e.message).to.include("Not eligible");
            }
        });

        it("Should allow claim after 72 hours", async function () {
            await network.provider.send("evm_increaseTime", [73 * 3600]); 
            await network.provider.send("evm_mine");
            const claimable = await rewardsVault.getClaimableAmount(user1.address);
            expect(claimable.gt(0)).to.be.true;
            
            const balBefore = await elx.balanceOf(user1.address);
            await rewardsVault.connect(user1).claimReward();
            const balAfter = await elx.balanceOf(user1.address);
            expect(balAfter.gt(balBefore)).to.be.true;
        });

        it("Should reset timer and claimable after successful claim", async function () {
            const claimable = await rewardsVault.getClaimableAmount(user1.address);
            expect(claimable.eq(0)).to.be.true;
        });
    });

    describe("3. Reserve Vault Autonomous Mechanics", function () {
        it("Should receive BNB directly from anyone", async function () {
            const stateBefore = await reserveVault.getVaultState();
            await deployer.sendTransaction({ to: reserveVault.address, value: ethers.utils.parseEther("1") });
            const stateAfter = await reserveVault.getVaultState();
            expect(stateAfter.balance.sub(stateBefore.balance).eq(ethers.utils.parseEther("1"))).to.be.true;
        });

        it("Should return correct ready state for buyback", async function () {
            const state = await reserveVault.getVaultState();
            // Should be false initially since no pressure
            expect(state.ready).to.be.false;
        });

        it("Should detect sell pressure and execute buyback atomically on Sell", async function () {
            const totalSupply = await elx.totalSupply();
            const bigSellAmt = totalSupply.mul(100).div(10000); 
            
            const deadBefore = await elx.balanceOf(BURN_ADDRESS);
            await elx.connect(user2).approve(router.address, bigSellAmt);
            await router.connect(user2).swapExactTokensForETHSupportingFeeOnTransferTokens(
                bigSellAmt, 0, [elx.address, wbnb.address], user2.address, ethers.constants.MaxUint256
            );
            
            const deadAfter = await elx.balanceOf(BURN_ADDRESS);
            expect(deadAfter.gt(deadBefore)).to.be.true;
        });

        it("Should enforce cooldown after execution", async function () {
            const state = await reserveVault.getVaultState();
            expect(state.ready).to.be.false;
        });
    });
});
