const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PancakeSwap V2 Local Testing", function () {
  let testToken;
  let testToken2;
  let owner;
  let addr1;

  before(async function () {
    [owner, addr1] = await ethers.getSigners();

    const TestToken = await ethers.getContractFactory("TestToken");
    testToken = await TestToken.deploy("Test Token A", "TTA", "1000000");
    await testToken.deployed();

    testToken2 = await TestToken.deploy("Test Token B", "TTB", "1000000");
    await testToken2.deployed();

    await testToken.transfer(addr1.address, ethers.utils.parseUnits("100000", 18));
    await testToken2.transfer(addr1.address, ethers.utils.parseUnits("100000", 18));
  });

  describe("Token Deployment", function () {
    it("Should have correct name and symbol", async function () {
      expect(await testToken.name()).to.equal("Test Token A");
      expect(await testToken.symbol()).to.equal("TTA");
    });

    it("Should mint tokens as owner", async function () {
      const beforeBalance = await testToken.balanceOf(owner.address);
      await testToken.mint(owner.address, ethers.utils.parseUnits("1000", 18));
      const afterBalance = await testToken.balanceOf(owner.address);
      expect(afterBalance).to.equal(beforeBalance.add(ethers.utils.parseUnits("1000", 18)));
    });

    it("Should burn tokens", async function () {
      const beforeBalance = await testToken.balanceOf(owner.address);
      await testToken.burn(ethers.utils.parseUnits("100", 18));
      const afterBalance = await testToken.balanceOf(owner.address);
      expect(afterBalance).to.equal(beforeBalance.sub(ethers.utils.parseUnits("100", 18)));
    });
  });

  describe("PancakeSwap V2 Integration Ready", function () {
    it("Tokens are ready for PancakeSwap pairs", async function () {
      const tokenAAddr = testToken.address;
      const tokenBAddr = testToken2.address;

      expect(tokenAAddr).to.be.properAddress;
      expect(tokenBAddr).to.be.properAddress;

      const ownerBalanceA = await testToken.balanceOf(owner.address);
      const ownerBalanceB = await testToken2.balanceOf(owner.address);

      expect(ownerBalanceA).to.be.gt(0);
      expect(ownerBalanceB).to.be.gt(0);
    });
  });
});
