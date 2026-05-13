const { expect } = require("chai");
const { ethers, network } = require("hardhat");

describe("ELX System - Production Tests", function () {
  let deployer, devWallet, user1, user2, user3, user4;
  let wbnb, factory, router, elx, reserveVault, rewardsVault, pair;
  const BURN_ADDRESS = "0x000000000000000000000000000000000000dEaD";

  // Use exact contract BPS math
  const calcTax = (amount) => {
    const totalTax = amount.mul(5).div(100);
    const devAmount = totalTax.mul(30).div(500);   // TAX_SHARE_DEV_BPS / 500
    const reserveAmount = totalTax.mul(30).div(500); // TAX_SHARE_RESERVE_BPS / 500
    const buybackAmount = totalTax.mul(440).div(500); // TAX_SHARE_BUYBACK_BPS / 500
    return { totalTax, devAmount, reserveAmount, buybackAmount };
  };

  async function fastForward(seconds) {
    await network.provider.send("evm_increaseTime", [seconds]);
    await network.provider.send("evm_mine");
  }

  beforeEach(async function () {
    [deployer, devWallet, user1, user2, user3, user4] = await ethers.getSigners();

    const WBNB = await ethers.getContractFactory("WBNB");
    wbnb = await WBNB.deploy(); await wbnb.deployed();

    const Factory = await ethers.getContractFactory("PancakeFactory");
    factory = await Factory.deploy(deployer.address); await factory.deployed();

    const Router = await ethers.getContractFactory("PancakeRouter02");
    router = await Router.deploy(factory.address, wbnb.address); await router.deployed();

    const ELXToken = await ethers.getContractFactory("ELXToken");
    elx = await ELXToken.deploy("ELX Token", "ELX", router.address, devWallet.address); await elx.deployed();

    const RewardsVault = await ethers.getContractFactory("RewardsVault");
    rewardsVault = await RewardsVault.deploy(elx.address); await rewardsVault.deployed();

    const ReserveVault = await ethers.getContractFactory("ReserveVault");
    reserveVault = await ReserveVault.deploy(elx.address, router.address); await reserveVault.deployed();

    await factory.createPair(elx.address, wbnb.address);
    const pairAddress = await factory.getPair(elx.address, wbnb.address);
    await elx.setVaults(reserveVault.address, rewardsVault.address, pairAddress);
    pair = await ethers.getContractAt("contracts/ELXToken.sol:IPancakePair", pairAddress);

    // Seed liquidity: 100M ELX / 100 BNB → price = 0.000001 BNB per ELX
    await elx.approve(router.address, ethers.utils.parseEther("100000000"));
    await router.addLiquidityETH(
      elx.address, ethers.utils.parseEther("100000000"),
      0, 0, deployer.address, ethers.constants.MaxUint256,
      { value: ethers.utils.parseEther("100") }
    );

    await elx.transfer(user1.address, ethers.utils.parseEther("50000000"));
    await elx.transfer(user2.address, ethers.utils.parseEther("50000000"));
  });

  // 1) Access control & initialization
  describe("1. Access Control & Initialization", function () {
    it("setVaults reverts for any non-deployer caller", async function () {
      await expect(
        elx.connect(user1).setVaults(user1.address, user1.address, user1.address)
      ).to.be.revertedWith("Not vault setter");
    });

    it("setVaults reverts on second call even from deployer", async function () {
      await expect(
        elx.setVaults(reserveVault.address, rewardsVault.address, pair.address)
      ).to.be.revertedWith("Vaults already set");
    });

    it("verifies post-setVaults immutable state", async function () {
      expect(await elx.reserveVault()).to.equal(reserveVault.address);
      expect(await elx.rewardsVault()).to.equal(rewardsVault.address);
      expect(await elx.pancakePair()).to.equal(pair.address);
      // Both vaults must be fee-excluded (they receive and swap tokens)
      expect(await elx._isExcludedFromFees(reserveVault.address)).to.be.true;
      expect(await elx._isExcludedFromFees(rewardsVault.address)).to.be.true;
    });

    it("emits VaultsSet with correct addresses", async function () {
      // Deploy fresh instance to call setVaults again
      const ELXToken = await ethers.getContractFactory("ELXToken");
      const freshElx = await ELXToken.deploy("T", "T", router.address, devWallet.address);
      await freshElx.deployed();
      await expect(freshElx.setVaults(reserveVault.address, rewardsVault.address, pair.address))
        .to.emit(freshElx, "VaultsSet")
        .withArgs(reserveVault.address, rewardsVault.address, pair.address);
    });
  });

  // 2) Taxation & transfers
  describe("2. Taxation & Transfers", function () {
    it("wallet-to-wallet: no tax, no event, exact balance delta", async function () {
      const amount = ethers.utils.parseEther("1000");
      const preU1 = await elx.balanceOf(user1.address);
      const preU2 = await elx.balanceOf(user2.address);

      await expect(elx.connect(user1).transfer(user2.address, amount))
        .to.not.emit(elx, "TaxTaken");

      expect(await elx.balanceOf(user1.address)).to.equal(preU1.sub(amount));
      expect(await elx.balanceOf(user2.address)).to.equal(preU2.add(amount));
    });

    it("buy: exact 5% tax with correct event args and wei-precise recipient balances", async function () {
      const bnbIn = ethers.utils.parseEther("1");
      const path = [wbnb.address, elx.address];
      const amountsOut = await router.getAmountsOut(bnbIn, path);
      const tokensFromPool = amountsOut[1];
      const { totalTax, devAmount, reserveAmount, buybackAmount } = calcTax(tokensFromPool);
      const expectedNet = tokensFromPool.sub(totalTax);
      const expectedContractIncrease = reserveAmount.add(buybackAmount);

      const preDev = await elx.balanceOf(devWallet.address);
      const preUser = await elx.balanceOf(user3.address);
      const preTaxQueue = await elx.tokensAccumulatedForTax();

      await expect(
        router.connect(user3).swapExactETHForTokensSupportingFeeOnTransferTokens(
          0, path, user3.address, ethers.constants.MaxUint256, { value: bnbIn }
        )
      ).to.emit(elx, "TaxTaken").withArgs(pair.address, user3.address, totalTax);

      // Buyer receives exactly pool_out - 5%
      expect(await elx.balanceOf(user3.address)).to.equal(preUser.add(expectedNet));
      // Dev receives exactly 0.3% of total amount
      expect(await elx.balanceOf(devWallet.address)).to.equal(preDev.add(devAmount));
      // Tax queue grows by the remaining 4.7%
      expect(await elx.tokensAccumulatedForTax()).to.equal(preTaxQueue.add(expectedContractIncrease));
    });

    it("sell: exact 5% tax with correct event args, pool gets net tokens", async function () {
      // Use amount below SWAP_TOKENS_AT_AMOUNT (10k) to prevent tax-swap from distorting pool
      const amountIn = ethers.utils.parseEther("10000");
      const { totalTax, devAmount, reserveAmount, buybackAmount } = calcTax(amountIn);
      const expectedToPool = amountIn.sub(totalTax);
      const expectedContractIncrease = reserveAmount.add(buybackAmount);

      const preUser = await elx.balanceOf(user1.address);
      const preDev = await elx.balanceOf(devWallet.address);
      const prePool = await elx.balanceOf(pair.address);
      const preTaxQueue = await elx.tokensAccumulatedForTax();

      await elx.connect(user1).approve(router.address, amountIn);
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amountIn, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "TaxTaken").withArgs(user1.address, pair.address, totalTax);

      expect(await elx.balanceOf(user1.address)).to.equal(preUser.sub(amountIn));
      expect(await elx.balanceOf(devWallet.address)).to.equal(preDev.add(devAmount));
      expect(await elx.balanceOf(pair.address)).to.equal(prePool.add(expectedToPool));
      expect(await elx.tokensAccumulatedForTax()).to.equal(preTaxQueue.add(expectedContractIncrease));
    });
  });

  // 3) Reserve buyback engine
  describe("3. Reserve Buyback Engine", function () {
    const SEED_BNB = ethers.utils.parseEther("5");

    beforeEach(async function () {
      // Seed reserve autonomously via receive() — no external actor needed beyond test setup
      await deployer.sendTransaction({ to: reserveVault.address, value: SEED_BNB });
      const state = await reserveVault.getVaultState();
      expect(state.balance).to.equal(SEED_BNB);
      expect(state.received).to.equal(SEED_BNB);
    });

    it("1.49% sell: no buyback, no BNB spent, distributed counter frozen", async function () {
      const supply = await elx.totalSupply();
      const amount = supply.mul(149).div(10000);
      await elx.connect(user1).approve(router.address, amount);

      const preDist = (await reserveVault.getVaultState()).distributed;

      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.not.emit(elx, "ReserveBuybackTriggered");

      const postState = await reserveVault.getVaultState();
      // No BNB was spent on a buyback — distributed must not change
      expect(postState.distributed).to.equal(preDist);
      // todayCount still zero
      expect(postState.todayCount).to.equal(0);
    });

    it("1.5% sell: buyback triggered, BNBDistributed increases, burn address grows", async function () {
      const supply = await elx.totalSupply();
      const amount = supply.mul(150).div(10000);
      await elx.connect(user1).approve(router.address, amount);

      const preState = await reserveVault.getVaultState();
      const preDead = await elx.balanceOf(BURN_ADDRESS);
      // Vault has BNB (balance check passes); volume threshold is crossed inside the tx
      expect(preState.balance).to.equal(SEED_BNB);

      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "ReserveBuybackTriggered");

      const postState = await reserveVault.getVaultState();
      // Count bumped
      expect(postState.todayCount).to.equal(preState.todayCount.add(1));
      // BNB was spent: distributed increased
      expect(postState.distributed).to.be.gt(preState.distributed);
      // Balance decreased by exactly the distributed delta
      const spent = postState.distributed.sub(preState.distributed);
      // balance_after = balance_before - spent  (no new BNB in same tx for this test)
      expect(postState.balance).to.equal(preState.balance.sub(spent));
      // Burn address must have more ELX than before
      expect(await elx.balanceOf(BURN_ADDRESS)).to.be.gt(preDead);
    });

    it("normal transfer does not change burn address; buyback does", async function () {
      const preDead = await elx.balanceOf(BURN_ADDRESS);

      // Non-pair transfer — no buyback, no burn
      await elx.connect(user1).transfer(user2.address, ethers.utils.parseEther("1000"));
      expect(await elx.balanceOf(BURN_ADDRESS)).to.equal(preDead);

      // Now trigger buyback via 1.5% sell
      const supply = await elx.totalSupply();
      const amount = supply.mul(150).div(10000);
      await elx.connect(user1).approve(router.address, amount);
      await router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
      );

      expect(await elx.balanceOf(BURN_ADDRESS)).to.be.gt(preDead);
    });
  });

  // 4) Buyback guards
  describe("4. Buyback Guards", function () {
    const SEED_BNB = ethers.utils.parseEther("5");

    beforeEach(async function () {
      await deployer.sendTransaction({ to: reserveVault.address, value: SEED_BNB });
    });

    it("4-hour cooldown: second identical sell does not trigger second buyback", async function () {
      const supply = await elx.totalSupply();
      const amount = supply.mul(150).div(10000);
      await elx.connect(user1).approve(router.address, amount);
      await elx.connect(user2).approve(router.address, amount);

      // Buyback 1
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "ReserveBuybackTriggered");
      expect((await reserveVault.getVaultState()).todayCount).to.equal(1);

      // Immediate second attempt — still in cooldown
      await expect(
        router.connect(user2).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user2.address, ethers.constants.MaxUint256
        )
      ).to.not.emit(elx, "ReserveBuybackTriggered");
      expect((await reserveVault.getVaultState()).todayCount).to.equal(1);
    });

    it("max 2 per day: third attempt blocked, new day resets counter to 1", async function () {
      const supply = await elx.totalSupply();
      const amount = supply.mul(150).div(10000);

      // Buyback 1
      await elx.connect(user1).approve(router.address, amount);
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "ReserveBuybackTriggered");

      await fastForward(4 * 3600 + 1);

      // Buyback 2
      await elx.connect(user1).approve(router.address, amount);
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "ReserveBuybackTriggered");
      expect((await reserveVault.getVaultState()).todayCount).to.equal(2);

      await fastForward(4 * 3600 + 1);

      // Buyback 3 — blocked by MAX_BUYBACKS_PER_DAY = 2
      await elx.connect(user1).approve(router.address, amount);
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.not.emit(elx, "ReserveBuybackTriggered");
      expect((await reserveVault.getVaultState()).todayCount).to.equal(2);

      // Advance full 24-hour reset window
      await fastForward(16 * 3600);

      // Buyback 4 — new day, counter resets then increments to 1
      await elx.connect(user1).approve(router.address, amount);
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "ReserveBuybackTriggered");
      expect((await reserveVault.getVaultState()).todayCount).to.equal(1);
    });
  });

  // 5) Rewards vault
  describe("5. Rewards Vault", function () {
    it("totalTokensReceived increases on deposit, ELX Transfer event emitted", async function () {
      const amount = ethers.utils.parseEther("100");
      const preTotalReceived = await rewardsVault.totalTokensReceived();

      await expect(elx.transfer(rewardsVault.address, amount))
        .to.emit(elx, "Transfer")
        .withArgs(deployer.address, rewardsVault.address, amount);

      // totalTokensReceived() = currentBalance() + totalTokensDistributed
      expect(await rewardsVault.totalTokensReceived()).to.equal(preTotalReceived.add(amount));
      expect(await elx.balanceOf(rewardsVault.address)).to.equal(amount);
    });

    it("premature claim reverts with exact message", async function () {
      await elx.transfer(rewardsVault.address, ethers.utils.parseEther("100"));
      await expect(rewardsVault.connect(user1).claimReward())
        .to.be.revertedWith("Not eligible or zero reward");
    });

    it("after 72h: claimable > 0, claim emits event, balances reconcile exactly", async function () {
      const amount = ethers.utils.parseEther("100");
      await elx.transfer(rewardsVault.address, amount);
      await fastForward(73 * 3600);

      const claimable = await rewardsVault.getClaimableAmount(user1.address);
      expect(claimable).to.be.gt(0);

      const preUser = await elx.balanceOf(user1.address);
      const preVault = await elx.balanceOf(rewardsVault.address);
      const preDistributed = await rewardsVault.totalTokensDistributed();

      await expect(rewardsVault.connect(user1).claimReward())
        .to.emit(rewardsVault, "RewardClaimed")
        .withArgs(user1.address, claimable);

      expect(await elx.balanceOf(user1.address)).to.equal(preUser.add(claimable));
      expect(await elx.balanceOf(rewardsVault.address)).to.equal(preVault.sub(claimable));
      expect(await rewardsVault.totalTokensDistributed()).to.equal(preDistributed.add(claimable));
      expect(await rewardsVault.userTotalClaimed(user1.address)).to.equal(claimable);
    });

    it("dilution: each claimant gets vault_balance / eligibleCount at claim time", async function () {
      const amount = ethers.utils.parseEther("200");
      await elx.transfer(rewardsVault.address, amount);
      await fastForward(73 * 3600);

      const eligibleCount = await elx.eligibleHoldersCount();
      // User1 claim
      const expectedU1 = (await elx.balanceOf(rewardsVault.address)).div(eligibleCount);
      const preU1 = await elx.balanceOf(user1.address);
      await rewardsVault.connect(user1).claimReward();
      expect(await elx.balanceOf(user1.address)).to.equal(preU1.add(expectedU1));

      // User2 claim — vault is now smaller but eligibleCount unchanged
      const expectedU2 = (await elx.balanceOf(rewardsVault.address)).div(eligibleCount);
      const preU2 = await elx.balanceOf(user2.address);
      await rewardsVault.connect(user2).claimReward();
      expect(await elx.balanceOf(user2.address)).to.equal(preU2.add(expectedU2));
    });
  });

  // 6) Holder tracking & hooks
  describe("6. Holder Tracking & Hooks", function () {
    it("crossing REWARD_THRESHOLD increments count; burning below decrements", async function () {
      const thresh = await elx.REWARD_THRESHOLD();
      const priorCount = await elx.eligibleHoldersCount();

      // user4 has 0 tokens — holderSince must be 0
      expect(await elx.holderSince(user4.address)).to.equal(0);

      // Send exactly threshold
      await elx.connect(deployer).transfer(user4.address, thresh);
      const since = await elx.holderSince(user4.address);
      expect(since).to.be.gt(0);
      expect(await elx.eligibleHoldersCount()).to.equal(priorCount.add(1));

      // Burn 1 wei below threshold
      await elx.connect(user4).burn(1);
      expect(await elx.holderSince(user4.address)).to.equal(0);
      expect(await elx.eligibleHoldersCount()).to.equal(priorCount);
    });

    it("claimReward resets holderSince to current block.timestamp", async function () {
      await elx.transfer(rewardsVault.address, ethers.utils.parseEther("100"));
      await fastForward(73 * 3600);

      const timerBefore = await elx.holderSince(user1.address);
      await rewardsVault.connect(user1).claimReward();
      const timerAfter = await elx.holderSince(user1.address);

      // Timer must have been reset to a later timestamp
      expect(timerAfter).to.be.gt(timerBefore);
    });

    it("excluded addresses (vaults) are never tracked as eligible holders", async function () {
      const countBefore = await elx.eligibleHoldersCount();
      // Transfer large amount to reserveVault (excluded)
      await elx.transfer(reserveVault.address, ethers.utils.parseEther("10000000"));
      // Count must not change
      expect(await elx.eligibleHoldersCount()).to.equal(countBefore);
      expect(await elx.holderSince(reserveVault.address)).to.equal(0);
    });
  });

  // Section 7: Protocol Edge Cases & Access Control
  describe("7. Protocol Edge Cases & Access Control", function () {
    it("ReserveVault.executeBuyback reverts for any caller except elxToken", async function () {
      await expect(reserveVault.connect(deployer).executeBuyback())
        .to.be.revertedWith("Only ELX token");
      await expect(reserveVault.connect(user1).executeBuyback())
        .to.be.revertedWith("Only ELX token");
    });

    it("ELXToken.resetRewardTimer reverts for any caller except rewardsVault", async function () {
      await expect(elx.connect(deployer).resetRewardTimer(user1.address))
        .to.be.revertedWith("Only rewards vault");
      await expect(elx.connect(user1).resetRewardTimer(user2.address))
        .to.be.revertedWith("Only rewards vault");
    });

    it("ReserveVault emits BNBReceived and increments totalBNBReceived exactly", async function () {
      const sendAmount = ethers.utils.parseEther("1");
      const preTotalReceived = await reserveVault.totalBNBReceived();
      await expect(deployer.sendTransaction({ to: reserveVault.address, value: sendAmount }))
        .to.emit(reserveVault, "BNBReceived")
        .withArgs(sendAmount);
      expect(await reserveVault.totalBNBReceived()).to.equal(preTotalReceived.add(sendAmount));
      expect(await ethers.provider.getBalance(reserveVault.address)).to.equal(sendAmount);
    });

    it("sell volume decays after 60+ minutes via bucket rotation", async function () {
      const sellAmount = ethers.utils.parseEther("5000000");
      await elx.connect(user1).approve(router.address, sellAmount);
      await router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        sellAmount, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
      );
      expect(await elx.getSellVolumeLastHour()).to.be.gt(0);

      await fastForward(61 * 60);

      const dustSell = ethers.utils.parseEther("1");
      await elx.connect(user1).approve(router.address, dustSell);
      await router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
        dustSell, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
      );

      const volumeAfterDecay = await elx.getSellVolumeLastHour();
      expect(volumeAfterDecay).to.be.lt(sellAmount);
      expect(volumeAfterDecay).to.be.lte(dustSell.add(ethers.utils.parseEther("1")));
    });

    it("tax swap fires at SWAP_TOKENS_AT_AMOUNT, emits SwapTokensForBNB", async function () {
      const SWAP_AT = await elx.SWAP_TOKENS_AT_AMOUNT();
      // 4.7% of sell goes to queue. Need: 0.047 * sellAmt >= 10000 → sellAmt >= SWAP_AT * 1000 / 47
      const sellToTrigger = SWAP_AT.mul(1000).div(47).add(ethers.utils.parseEther("1000"));
      await elx.connect(user1).approve(router.address, sellToTrigger);
      await expect(
        router.connect(user1).swapExactTokensForETHSupportingFeeOnTransferTokens(
          sellToTrigger, 0, [elx.address, wbnb.address], user1.address, ethers.constants.MaxUint256
        )
      ).to.emit(elx, "SwapTokensForBNB");
      expect(await elx.tokensAccumulatedForTax()).to.be.lt(SWAP_AT);
    });

    it("fee-excluded deployer transfers full amount with no TaxTaken event", async function () {
      const amount = ethers.utils.parseEther("1000000");
      const preDev = await elx.balanceOf(devWallet.address);
      const preUser3 = await elx.balanceOf(user3.address);
      await expect(elx.connect(deployer).transfer(user3.address, amount))
        .to.not.emit(elx, "TaxTaken");
      expect(await elx.balanceOf(user3.address)).to.equal(preUser3.add(amount));
      expect(await elx.balanceOf(devWallet.address)).to.equal(preDev);
    });

    it("burn reduces totalSupply exactly and clears holderSince below threshold", async function () {
      const thresh = await elx.REWARD_THRESHOLD();
      expect(await elx.holderSince(user1.address)).to.be.gt(0);
      const supplyBefore = await elx.totalSupply();
      const balance = await elx.balanceOf(user1.address);
      const burnAmount = balance.sub(thresh).add(1);
      await elx.connect(user1).burn(burnAmount);
      expect(await elx.totalSupply()).to.equal(supplyBefore.sub(burnAmount));
      expect(await elx.holderSince(user1.address)).to.equal(0);
    });

    it("burnFrom enforces allowance, reduces supply, clears allowance to zero", async function () {
      const burnAmt = ethers.utils.parseEther("1000");
      await elx.connect(user1).approve(user2.address, burnAmt);
      const supplyBefore = await elx.totalSupply();
      const balBefore = await elx.balanceOf(user1.address);
      await elx.connect(user2).burnFrom(user1.address, burnAmt);
      expect(await elx.totalSupply()).to.equal(supplyBefore.sub(burnAmt));
      expect(await elx.balanceOf(user1.address)).to.equal(balBefore.sub(burnAmt));
      expect(await elx.allowance(user1.address, user2.address)).to.equal(0);
    });
  });
});
