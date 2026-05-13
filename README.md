# ELX System - Contracts Overview

This repository contains an ELX token system with three main smart contracts: `ELXToken`, `ReserveVault`, and `RewardsVault`.

Summary:
- `ELXToken` (contracts/ELXToken.sol): The main ERC-20 token with deflationary mechanics, buy/sell taxes, automated tax processing, liquidity additions, and buyback/burn logic.
- `ReserveVault` (contracts/ReserveVault.sol): Holds BNB reserves collected for periodic automated buybacks of ELX, then burns purchased tokens. Contains frequency and cooldown guards.
- `RewardsVault` (contracts/RewardsVault.sol): Holds ELX tokens reserved as rewards and allows eligible holders to claim rewards after a holding period.

ELXToken (high level)
- Purpose: ERC-20 with a split tax on buys/sells. Taxes fund: developer, reserve vault, and buyback/rewards/liquidity distributions.
- Key constants: `TOTAL_SUPPLY`, `BURN_AMOUNT`, `buyTaxPercent`, `sellTaxPercent`, basis-point split constants for tax distribution.
- Vaults: `reserveVault` and `rewardsVault` are set once via `setVaults()` by the `vaultSetter`.
- Automatic flows:
  - On sells, the token records recent sell volume (12 buckets of 5 minutes each) to measure sell pressure.
  - When thresholds are met, tokens collected for tax are swapped to BNB and distributed: some to `reserveVault`, some to buyback/rewards, and some for adding liquidity.
  - Buybacks: token swaps for BNB perform rewards distribution and burns; leftover dust is carried forward.
- Safety: `lockTheSwap` modifier prevents re-entrancy into swap paths; external vaults implement further checks.

ReserveVault (high level)
- Purpose: Receive BNB from token tax processing and execute controlled buybacks of ELX (swapping BNB → ELX) that are burned.
- Key guards: daily max buybacks (`MAX_BUYBACKS_PER_DAY`), cooldown (`BUYBACK_COOLDOWN`), and minimum reserve floor (`MIN_RESERVE_BALANCE`).
- Triggers: `ELXToken` calls `shouldExecuteBuyback()` and `executeBuyback()` when sell pressure and available reserves meet configured thresholds.
- Swap details: Uses Pancake/Uniswap router to swap `WBNB` → `ELX`; slippage-protected via `slippageBps`.

RewardsVault (high level)
- Purpose: Hold ELX tokens earmarked as rewards and allow eligible holders to claim them after meeting holding-duration requirements.
- Eligibility: `ELXToken` tracks `holderSince` and `eligibleHoldersCount`. `RewardsVault` calculates per-holder share based on current vault balance and eligible holder count.
- Claiming: `claimReward()` enforces a minimum waiting period (`REWARD_DURATION`) and resets the holder timer via `elxToken.resetRewardTimer()` after successful claims.

Deployment & Notes
- Deploy `ELXToken` with constructor params: name, symbol, routerAddress, devWallet. The deployer becomes `vaultSetter` and should call `setVaults()` once `ReserveVault` and `RewardsVault` are deployed.
- Deploy `ReserveVault` with the deployed `ELXToken` address and router address.
- Deploy `RewardsVault` with the deployed `ELXToken` address.
- Ensure router addresses are correct for the target network (Pancake on BSC, Uniswap on ETH-compatible networks); `WBNB`/WETH is queried from the router.

Security Considerations
- External calls to routers and vaults are try/catch wrapped to avoid blocking transfers.
- `lockTheSwap` prevents re-entrancy during swaps, and `ReentrancyGuard` is used in vaults.
- Carefully control private keys for `vaultSetter` and the `devWallet` role.

Where to find the contracts
- `ELXToken`: [contracts/ELXToken.sol](contracts/ELXToken.sol)
- `ReserveVault`: [contracts/ReserveVault.sol](contracts/ReserveVault.sol)
- `RewardsVault`: [contracts/RewardsVault.sol](contracts/RewardsVault.sol)

If you want, I can also:
- Add a deployment script or Hardhat tasks to deploy these three contracts and automatically call `setVaults()`.
- Add more detailed security notes or unit tests for buyback/claim flows.

Extended notes for auditors and integrators
-----------------------------------------

This section is written for a developer or auditor who will review the contracts and validate behaviour before any production deployment.

1) Contract responsibilities (detailed)
- `ELXToken` (`contracts/ELXToken.sol`):
  - Constructor: mints total supply to deployer, immediately burns `BURN_AMOUNT`, sets `vaultSetter`, stores `devWallet` and the router reference, and reads `WETH()`/`WBNB` from the router. Verify router address correctness before deployment.
  - `_transfer`: applies buy/sell tax when interacting with `pancakePair`. Splits tax into dev, reserve, and buyback portions. Moves tokens for conversion into the token contract and increments `tokensForTax`.
  - `_processTaxSwap` / `_distributeTaxes`: swaps collected tokens to BNB, splits BNB between `reserveVault` and buyback flows, adds LP (half token/half BNB) sending LP tokens to burn address, and performs buyback swaps for rewards and burns.
  - Sell tracking: 12 circular buckets of `BUCKET_DURATION` (5 minutes) track recent sell volume; used to detect sell-pressure for reserve buybacks.
  - Vault management: `setVaults()` is callable only by `vaultSetter` and only once; it sets `reserveVault`, `rewardsVault` and `pancakePair` and excludes vaults from fees.
  - Timers & rewards eligibility: maintains `holderSince` and `eligibleHoldersCount`; `RewardsVault` relies on these values to compute claims.

- `ReserveVault` (`contracts/ReserveVault.sol`):
  - Receives BNB from `ELXToken._distributeTaxes` and makes a decision whether to call `executeBuyback()` based on `shouldExecuteBuyback()`.
  - `executeBuyback()`: swaps BNB for ELX via router, burns the acquired ELX, and enforces daily and cooldown limits.
  - Important checks: ensure `shouldExecuteBuyback()` logic cannot be trivially triggered by attackers and that limits prevent draining reserves.

- `RewardsVault` (`contracts/RewardsVault.sol`):
  - Receives ELX (via buybacks distribution) and allows eligible holders to `claimReward()`.
  - Claim calculation: often proportional to `balanceOf(rewardsVault)` and `eligibleHoldersCount` at claim time. Confirm the formula and edge-cases (division by zero, rounding, state updates).
  - Resets holder timer via `elxToken.resetRewardTimer()` upon successful claim.

2) Audit checklist (quick actionable items)
- Construction & initialization
  - Confirm router addresses and `WBNB`/`WETH` values prior to deploying `ELXToken` — constructor calls `pancakeRouter.WETH()` and will revert or misbehave if router is unreachable or wrong.
  - Verify `setVaults()` is only callable by `vaultSetter` and only once.

- Token flows & accounting
  - Trace a full sell path (user -> pair) and verify `_transfer` tax calculations and resulting token movements to `devWallet`, contract, and burn.
  - Validate `tokensForTax` accounting under repeated swaps and edge conditions (partial swaps, failed swaps, re-entrancy attempts).
  - Confirm leftover token handling (contract burns leftover tokens after _distributeTaxes).

- External integrations (router, vaults)
  - Verify try/catch branches for router calls behave safely (do not lock user funds and do not leave inconsistent accounting).
  - Confirm `ReserveVault.executeBuyback()` cannot be called by arbitrary addresses and that `shouldExecuteBuyback()` logic is robust.

- Sell-pressure and buyback triggers
  - Simulate sell bursts that rotate buckets and check whether `getSellVolumeLastHour()` and thresholds identify the intended events.
  - Verify buyback cooldowns and max-per-day constraints in `ReserveVault`.

- Rewards & eligibility
  - Check `holderSince` lifecycle: mint, transfer-in, transfer-out, and claim reset behaviors.
  - Ensure `RewardsVault.claimReward()` handles edge cases when `eligibleHoldersCount` is zero.

- Gas, upgrade & safety
  - Review expensive loops (12 buckets are constant; gas cost acceptable) and verify no unbounded loops exist.
  - Confirm `lockTheSwap` and `ReentrancyGuard` usage protects swap entrypoints.
  - Consider making critical parameters configurable via owner/guardian, with multisig control for production.

3) Recommended test scenarios (minimum)
- Unit tests
  - Tax math: assert tax splits for buy and sell with multiple token amounts.
  - Swap path: simulate `_distributeTaxes()` success and failure (router revert) and confirm accounting.
  - Reserve buyback: simulate `shouldExecuteBuyback()` true and false, confirm `executeBuyback()` burns tokens and respects limits.
  - Rewards claiming: test eligibility thresholds and claims resetting timers.

- Integration
  - Run `client_presentation_demo.js` (local mocks) to exercise end-to-end flows.
  - Run `mainnet_fork_test.js` on a forked BSC node (export `FORK=true` and provide a `BSC_FORK_URL` in env) to test against the real Pancake router state.

4) Deploy & run (quick commands)
To run tests and demos locally:
```powershell
npm install
npx hardhat test
npx hardhat run scripts/client_presentation_demo.js
```

To run a mainnet fork test (requires BSC archive RPC):
```powershell
setx BSC_FORK_URL "https://bsc-mainnet.g.alchemy.com/v2/YOUR_KEY"
setx FORK true
npx hardhat run scripts/mainnet_fork_test.js --network hardhat
```

5) Contact & next steps
- If you want, I can add a dedicated `AUDIT.md` or expand automated tests for the buyback/claim edge cases. Say the word and I will add targeted unit tests and a deployment task that runs `setVaults()` automatically after liquidity is created.

---
This README addition aims to give a clear, developer-focused summary for auditors and integrators. Tell me if you want any of the checklist items implemented as tests or scripts next.
