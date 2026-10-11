# Money Back Mutual · IMD Money Back ($MONEYBACK)

Launch preparation for Robinhood Chain **4663**, paired with IMD. Website: https://imdmoneyback.xyz · X: https://x.com/IMDmoneyback.

The four supplied contracts came from swarm jobs `57052175` and `cb7160d0`. This revision repairs the imported partial-fill fee issue and router payment pattern, supplies a protocol-compatible manifest and a separate auxiliary deployment script, and preserves the requested fee constants, permissions, token supply and ownership. `MoneyBackToken.sol` and `RoundPayout.sol` are unchanged. No transaction has been broadcast by this work.

## Deliverables and checks

- [launch.json](launch.json): installed IMD `univ4_hook` format, deploying the token and hook.
- [DeployAuxiliaries.s.sol](script/DeployAuxiliaries.s.sol): deploys RoundPayout and MoneyBackRouter after the factory launch, with explicit address validation.
- [Requester share](docs/requester-share.json): the protocol's two-field requester-share input, for the launch service; **not an additional launch manifest** and not automatically consumed by `launch.json`.
- [Audit responses](docs/AUDIT_RESPONSES.md): disposition of all eight imported entries, test evidence and validation limits.
- [Network observations](docs/network-observations.json): pinned, read-only checks of IMD and the public ETH/IMD pool.
- [PNG logo](assets/moneyback.png) and [SVG source](assets/moneyback.svg): one large, centered open umbrella with a hooked handle, `#FFC83D` on a full-square `#17356B` background. The PNG is 1024 × 1024 RGB; no text, rain, border or gradient.

Run from the repository root:

```sh
forge build
forge test
forge fmt --check
imd launch check .
```

The protected configuration pins Solidity **0.8.26**, Cancun, optimizer 200 runs and no bytecode hash. It is unchanged. Production contracts use inlined interfaces and internal helpers. The real-PoolManager tests include their minimal source dependencies as ordinary files under `test/vendor/`, with pinned revisions and licenses; they require no download, environment variables, FFI, filesystem permissions, submodules or RPC. See [test dependency provenance](test/vendor/README.md).

## Fixed deployment parameters

| Item | Required value |
| --- | --- |
| Token | `MoneyBackToken()`; name `IMD Money Back`, symbol `MONEYBACK`, 18 decimals |
| Supply | `1000000000000000000000000000` minor units: 1,000,000,000 tokens, minted once to the factory |
| Hook | `MoneyBackHook($poolManager, $token, $owner)` |
| Owner / immutable hook payout | Paying wallet `0x57797cba5196a87959a0b8f1b8a42e5aed721eac` |
| Hook address bits | Low 14 bits exactly `0x20CC` |
| Permissions | `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` |
| Paired currency | IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals) |
| LP fee / spacing | `12500` (1.25%) / `60` |
| Manifest initialPrice | `"79228162514264337593543950336"` (2^96), explicitly supplied by the brief |
| Opening valuation policy | 2,500 IMD for the whole supply; actual opening sqrt price derived by the launch deployer using the final currency ordering |
| Auxiliary payer | `RoundPayout(paying wallet)` |
| Auxiliary router | `MoneyBackRouter(actual poolManager, actual mined hook address)` |

The manifest's initialPrice is the brief's protocol provenance value. It is not an instruction to bypass the launch policy's address-dependent opening-price calculation. Both assets have 18 decimals; the stated opening valuation corresponds to 0.0000025 IMD per MONEYBACK. The factory resolves `$poolManager` and `$token`, mines the hook address for **the final compiled bytecode and arguments**, deploys the hook, and initializes its pool in the same transaction. Do not reuse a pre-repair CREATE2 salt. No PoolManager address is hardcoded in production source, deployment scripts or the manifest.

### Token distribution

The factory, not the token constructor or auxiliary contracts, implements this distribution:

| Destination | Calculation | Tokens | Share of total |
| --- | --- | ---: | ---: |
| Swarm seats via launch MerkleDistributor | Supply × 10% | 100,000,000 | 10% |
| Single-sided launch pool | Requester 90% × `poolBps 9000 / 10000` | 810,000,000 | 81% |
| Dead address | Remaining 10% of requester share | 90,000,000 | 9% |
| Team, hook, router, RoundPayout | No allocation | 0 | 0% |

Set requester-share `poolBps = 9000`, the maximum, and `remainderTo = 0x000000000000000000000000000000000000dead`. The dead address is the **explicitly requested burn destination**, not an owner or constructor placeholder. Sending there does not reduce ERC-20 `totalSupply`; there is no callable burn or mint function. The team receives no launch-token allocation; the paying wallet still receives the hook's IMD fees and any rights or LP revenue assigned by launch policy.

The installed hook manifest has no economics fields. The launch service must carry these values into its launch-task economics and check the factory's distribution receipts; adding unknown JSON keys would not enforce them. No requested allocation is replaced by a token-level transfer tax or extra mint.

## Fee behavior

The hook binds one pool and accepts callbacks only from its immutable PoolManager. It has no owner, fee setter, payout setter, pause, upgrade or arbitrary execution function. The token and router also have no administrative powers.

```text
baseFee   = floor(imdLeg * 425 / 10000)
sellBps   = floor(2000 * max(0, 1800 - elapsedSeconds) / 1800)
surcharge = isSell ? floor(imdLeg * sellBps / 10000) : 0
hookFee   = baseFee + surcharge
```

Elapsed time starts at pool initialization and uses `block.timestamp`. The surcharge is 2000 bps initially, 1000 at +900 seconds, and 0 from +1800 seconds onward. Buys never incur it. The two fee components round down separately. The 1.25% pool LP fee is separate and is never overridden.

| Swap | IMD leg and fee treatment | Partial fills |
| --- | --- | --- |
| Exact-input buy | Offered IMD is the leg; hook takes 4.25%, pool consumes the remainder | Reverts `PartialFill` unless the adjusted IMD input is completely consumed |
| Exact-output buy | Actual pool IMD input is the leg; fee is added to that input | Fee reflects actual fill; caller must enforce required MONEYBACK output |
| Exact-input sell | Actual pool IMD output is the leg; base fee and surcharge are deducted | Allowed; fee reflects actual fill and unused MONEYBACK can be refunded |
| Exact-output sell | Requested net IMD is the leg; pool must deliver that amount plus base fee and surcharge | Reverts `PartialFill` unless that entire gross IMD output is delivered |

The full-fill guard compares the actual pool IMD delta with `amountSpecified + beforeSwapFee`. Its fee calculation is deterministic within the transaction: constants, the pool's fixed initialization time and the same block timestamp. Recomputing the separately floored components avoids transient state and supports several swaps in one unlock. Reverting also rolls back all claims and both router legs. A quote for an unfillable IMD-specified swap reverts; use a smaller executable trade.

Fees accrue as ERC-6909 **IMD claims**, allowing first buys even when a pool seeded only with MONEYBACK has no IMD in the manager yet. Anyone can call `sweep()` outside an existing manager unlock. It burns the claims and transfers IMD only to the immutable paying wallet. If redemption fails, the transaction reverts and claims remain. The hook never sells fees for ETH, never charges MONEYBACK and never sends fees to RoundPayout automatically.

The router's public route is native ETH / IMD, fee 10000, tick spacing 100, no hook. Its ETH conversions concern the **trader's input or proceeds**; hook fees remain in IMD. Sellers approve this router, which pulls only from `msg.sender` before unlocking, settles only consumed MONEYBACK from its own balance, and returns unused MONEYBACK afterward. It also refunds unused ETH and IMD where the relevant leg permits a partial fill. Set minimum output and deadline on every trade; quotes use `eth_call` and roll back their simulation.

### Scope of the surcharge

Flags `0x20CC` include no liquidity callbacks. A holder can supply single-sided liquidity, let others buy through it, and remove IMD without a sell swap of their own. OTC transfers and trades in other pools also fall outside this hook. The surcharge is a fee on swaps through this pool, not a guarantee that every economic sale is taxed. Adding a liquidity restriction would change the explicitly fixed permission requirements, so this revision retains them and includes a real-v4 regression demonstrating the limit.

## Deployment sequence

1. The network completes its independent review and attests the final compiled source and manifest. The launch service uses chain 4663, the paying wallet, the requester-share values above and the policy opening valuation.
2. The factory deploys MoneyBackToken, distributes/seeds according to those economics, and deploys and initializes MoneyBackHook at an address with bits `0x20CC`. Record the real manager, token and hook addresses, pool key, opening price, distribution receipts and LP position from that launch.
3. Deploy **RoundPayout and MoneyBackRouter separately**. The installed `univ4_hook` schema only deploys the token and hook: it has neither a `contracts` array nor a `$contract:MoneyBackHook` resolver. `script/DeployAuxiliaries.s.sol` validates chain, nonempty deployments, manager/hook agreement, paying wallet, flags and pool initialization, then creates both auxiliaries. Its constructor arguments contain the actual resolved hook address. The router constructor reads `launchToken()` from that already-deployed hook.
4. Record both auxiliary receipts and returned addresses, verify all four deployed contracts against the final build, and configure the website/engine with those actual addresses. The four-contract launch is incomplete until both auxiliary deployments exist. Never run the auxiliary script again blindly after a partial broadcast; inspect receipts first and deploy only any missing contract with the same arguments.

For an authorized deployer, this command performs a simulation using addresses obtained from the factory launch receipt and its network configuration:

```sh
forge script script/DeployAuxiliaries.s.sol:DeployAuxiliaries \
  --sig 'run(address,address)' "$MONEYBACK_POOL_MANAGER" "$MONEYBACK_HOOK" \
  --rpc-url "$MONEYBACK_RPC"
```

These shell variables are explicit run arguments, not values read by contracts or tests. The script uses no environment cheatcodes. Signing and adding `--broadcast` belong to the network's authorized deployment process; this assignment neither supplies a private key nor executes those transactions. On this worker the chain relay is `http://127.0.0.1:44055/rpc/4663`; it is not a public production endpoint.

## After launch

The paying wallet owns **only RoundPayout**. Any account can call the hook's `sweep()` and anyone can fund RoundPayout, but an operator must move swept IMD from the wallet into the payer: approve the actual RoundPayout address on IMD, then call `fund(IMD, amount)`. No pool, router or hook funding of rounds happens automatically.

The engine runs off chain. Its operator determines eligible recipients, losses, round IDs, amounts, ledger hash and supplied price data; the payer does not validate an insurance entitlement or price oracle. The contract does not enforce a 15-minute schedule. Use unique recipients per batch, at most 500 entries, and sufficient funding; a completed round ID is idempotent. Monitor `Paid`, `PayFailed` and `RoundPaid`, retry failures with `retryFailed`, or explicitly write them off with `writeOffFailed`.

The RoundPayout owner can choose arbitrary recipients, amounts and ERC-20s, sweep its entire token balance anywhere (also while paused), pause/unpause new payments and retries, transfer ownership through the two-step handoff, or renounce it. Renouncing disables future owner operations. These powers do not alter the token, hook, router or holder balances. The owner is responsible for maintaining its signer, funding and operating the engine, reconciling actual transfers, publishing the ledger and monitoring claims/round failures. All contract bytecode remains immutable, including RoundPayout; its allowed owner operations affect its state, not its code.

## Worker-selected implementation choices

The original brief fixes all economic values and the paying wallet. The worker selected atomic rejection of unsafe specified-currency partial fills, settlement from router-held caller funds, separate auxiliary deployment using the installed protocol's supported boundary, and vector artwork plus a 1024-pixel PNG. These are documented implementation choices, not new requester approvals. No market quote, external owner, launch address, key or signature was invented.
