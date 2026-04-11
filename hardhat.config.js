require("@nomiclabs/hardhat-ethers");
require("dotenv").config();

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.4.18",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      {
        version: "0.6.6",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      {
        version: "0.8.19",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    ],
  },
  networks: {
    hardhat: {
      chainId: 56,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
    },
    bsc_testnet: {
      url: "https://data-seed-prebsc-1-b7c35f7.binance.org:8545",
      chainId: 97,
      gasPrice: 10e9,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    bsc_mainnet: {
      url: "https://bsc-dataseed1.binance.org",
      chainId: 56,
      gasPrice: 5e9,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },
};
