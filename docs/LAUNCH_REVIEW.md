# Launch review: Robinhood Chain, pinned commit

This record accompanies the launch of IMD Money Back ($MONEYBACK) from the pinned commit. The production sources (`src/`), the deployment script, `foundry.toml` and `launch.json` are the ones the swarm delivered and the earlier launch job accepted: **no production bytecode changed in this pass**. The work here reproduced the four imported audit findings against the real vendored v4-core PoolManager, added the regression tests listed below, and brought the documentation into line with the launch rules. Everything was run offline; no transaction was broadcast and no key was used.

## Imported findings

### 1. `e1b55a37…` (low): sell surcharge and base fee bypassed through a single-sided LP position

**Reproduced.** `test_liquidityConversionIsOutsideSwapSurcharge` in `test/MoneyBackRealV4.t.sol` runs the exact sequence against the real PoolManager in both currency orders: a MONEYBACK-only position just above the price, a buyer trading through it, and the position withdrawn as IMD inside the 1800 s window while `pending()` holds only the buyer's fee and `currentSurchargeBps()` is still 2000.

**Not changed, by design.** The brief fixes the hook flags at `0x20CC`, which carry no liquidity callbacks, and says the fee parameters must not change. Closing this path needs `beforeAddLiquidity`/`beforeRemoveLiquidity` permissions, a different mined address and a different manifest, none of which this launch authorises. The surcharge is a fee on swaps through this pool, not a guarantee that every economic sale of MONEYBACK is taxed; the README's "Scope of the surcharge" section says so for holders and the requester. The 10% swarm seats are the holders most able to use it during the window.

### 2. `9c5310a6…` (low): manifest `initialPrice` is parity while the docs state a 2,500 IMD opening valuation

**Reproduced as a documentation gap, not a code defect.** Initializing at `79228162514264337593543950336` does open a parity pool (1 IMD buys about 0.947 MONEYBACK after fees), as the auditor measured.

**Resolved by the launch rules, documented here, tested.** The launch policy states that `pool.initialPrice` is the literal `"79228162514264337593543950336"` and that the deployer does *not* open the pool at it: it derives the opening price from the policy's opening market cap of 2,500 IMD for the whole supply and the token's final address, which fixes which currency sorts first. The manifest therefore keeps the literal the policy requires, and the README now gives both candidate opening prices so the deployer's choice can be checked against the sort order:

| Sort order after mining | Price | sqrtPriceX96 | Tick |
| --- | --- | ---: | ---: |
| MONEYBACK is currency0 (token address < IMD) | 0.0000025 IMD per MONEYBACK | `125270724187523965593206901` | about -128,999 |
| MONEYBACK is currency1 (token address > IMD) | 400,000 MONEYBACK per IMD | `50108289675009586237282760313921` | about 128,998 |

Derivation: both assets have 18 decimals, so price1/price0 is 2,500 / 1,000,000,000 = 2.5e-6 when MONEYBACK is currency0 and its inverse otherwise; sqrtPriceX96 = sqrt(price1/price0) × 2^96. Both are inside v4's `MIN_SQRT_PRICE`/`MAX_SQRT_PRICE` bounds.

New tests (both currency orders): `test_policyOpeningPriceSingleSidedSeedFirstBuyAndSweep` opens the pool at the derived price, seeds 810,000,000 MONEYBACK single-sided on the MONEYBACK side of the price with no IMD in the manager, buys with 1 IMD and receives about 374,000 to 377,000 MONEYBACK (400,000 less the 4.25% hook fee, the 1.25% LP fee and the tick-spacing gap to the first liquidity), accrues the fee as an IMD claim and sweeps it to the payout wallet. `test_policyOpeningPriceSellSurchargeApplies` checks the 24.25% sell rate at that price. The existing suite continues to cover the parity price, so the hook accepts whichever the deployer passes: `beforeInitialize` deliberately does not read `sqrtPriceX96`.

### 3. `cf9fbd17…` (info): `beforeInitialize` does not check the initializing `sender`

**Reproduced.** `test_unboundHookIsBoundByWhoeverInitializesFirst` deploys the hook without initializing it, has an unrelated address call `PoolManager.initialize` at `MIN_SQRT_PRICE + 1`, and shows the hook bound at that price with the surcharge clock started, after which the factory's own initialize reverts `AlreadyBound`.

**Not changed, by design; the launch flow closes it.** The launch factory deploys the hook and initializes its pool in one transaction, so no such window exists on Robinhood Chain. Closing it in code means a `$factory` constructor argument, a new constructor signature, a re-mined address and a changed manifest; the brief asks for the pinned code to launch as it is, and the auditor recorded the item for awareness rather than change. The operational rule that follows is the one that matters: **never deploy MoneyBackHook at its mined address without initializing the pool in the same transaction, and never redeploy it.** `test_boundPoolRefusesAnySecondInitialize` shows that once bound, no key and no price can bind the hook again, from any sender.

### 4. `7d83a6b7…` (info): audit scope

Nothing to fix. The limits the auditor listed still hold for this pass: the live IMD bytecode, the live PoolManager, the public ETH/IMD pool, the launch factory and the MerkleDistributor were not reached offline. The router's public pool constants match only the pinned observation in `docs/network-observations.json`.

## Checks run in this pass

| Check | Result |
| --- | --- |
| `forge build` (solc 0.8.26, Cancun, optimizer 200, as pinned) | Exit 0 |
| `forge test` | Exit 0; 239 passed, 0 failed, 0 skipped across 7 suites |
| `forge fmt --check` | Exit 0 |
| Logo `assets/moneyback.png` | 1024 × 1024 RGB PNG; one yellow `#FFC83D` open umbrella with hooked handle on flat navy `#17356B`, nothing else; `assets/moneyback.svg` is the editable source |
| Production source diff against the pinned commit | None |

Slither, Mythril and a live-chain fork did not run here; Slither runs on the verifier. These local checks are not an audit.

## Deployment parameters

| Item | Value |
| --- | --- |
| Chain | Robinhood Chain, id 4663 |
| Contracts the factory deploys | `MoneyBackToken()`, then `MoneyBackHook($poolManager, $token, $owner)` |
| `$owner` | `0x57797cba5196a87959a0b8f1b8a42e5aed721eac`, the paying wallet; it is the hook's immutable `payout` |
| Hook address | Low 14 bits exactly `0x20CC`; salt mined against the final bytecode and resolved arguments |
| Pool | MONEYBACK / IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, LP fee 12500, tick spacing 60, this hook; any other key reverts in `beforeInitialize` |
| Manifest `initialPrice` | `"79228162514264337593543950336"` (policy literal); opening price derived by the deployer per the table above |
| Supply split | 10% swarm seats via MerkleDistributor; requester 90% with `poolBps 9000` and `remainderTo 0x…dEaD`: 81% single-sided in the pool, 9% to the dead address, 0% to the team |
| Hook fee | 425 bps of the pool's IMD leg on every swap, both directions; plus a sell-only surcharge of 2000 bps decaying linearly to 0 over 1800 s from initialization |
| Fee custody | ERC-6909 IMD claims owned by the hook; `sweep()` is permissionless and sends IMD only to `payout`; fees are never sold for ETH |
| Admin surface | None in the token, hook or router; only `RoundPayout` has an owner (`$owner`) |
| Deployed afterwards by the requester | `RoundPayout($owner)` and `MoneyBackRouter($poolManager, <mined hook address>)` via `script/DeployAuxiliaries.s.sol`; their absence from the factory launch is expected |

## Operational responsibilities after launch

- **Deployer (launch service):** deploy and initialize the hook in one transaction; record the manager, token and hook addresses, the opening sqrtPriceX96 actually used, the distribution receipts and the seed position.
- **Requester:** run `DeployAuxiliaries` once with the real manager and hook addresses, keep both receipts, and verify all four contracts against the final build. Fund `RoundPayout` explicitly (approve IMD, then `fund`) from swept IMD; nothing funds it automatically.
- **Anyone:** call `sweep()` on the hook whenever claims have accrued; the IMD goes to the paying wallet regardless of caller.
- **Holders and the requester:** understand that the sell surcharge applies to swaps in this pool only; LP conversions, OTC transfers and other venues are outside it.
