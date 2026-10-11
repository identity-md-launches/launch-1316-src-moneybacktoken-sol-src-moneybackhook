# Money Back regression and invariant coverage

These tests extend the accepted implementation at
`d36291dfe05e3782fedf32c65a683ef9526c2ff3`. All production contracts,
launch parameters, dependencies and configuration remain unchanged. The existing
250 tests are retained. The shared real-v4 setup was separated from its scenario
tests so the new suite can reuse the same deployment and liquidity helpers.

## Added coverage

`MoneyBackStatefulV4.t.sol` uses the vendored **real PoolManager**, the production
MONEYBACK token, hook and router, and an ERC-20 mock at the fixed IMD address. It
runs in both sorted currency orders, with three router users and a direct swap
handler. Its nine randomized actions exercise:

- All four exact-input/output and buy/sell combinations, including four swaps
  within one unlock followed by net settlement.
- Two-pool ETH routing, state-neutral quotes and slippage failures.
- IMD-specified partial-fill rejection at the current pool price.
- Externally funded IMD claims, permissionless sweeps and time advancement.

The fee oracle uses the PoolManager's `Swap` events to obtain the actual pool-side
IMD movement. It compares that movement to the hook's fee events, user deltas and
ERC-6909 claims; it does not copy the hook's inverse-fee formula. It checks the
pinned one/two-wei rounding allowances and the fixed 12,500-pip LP fee.

After each operation, the tests check settlement while transient storage is still
visible. Global invariants reconcile accrued/gifted/redeemed claims, recipient
balances, claim backing, and conservation of MONEYBACK, IMD and ETH across every
participating account. Normal trades leave the router with no assets. Quotes and
rejected calls must preserve both pools' prices, ticks, liquidity and fee-growth
accumulators, balances, router allowances and hook claims.

Additional scenarios cover a stale quote after another user's buy, a recipient
that rejects ETH, an IMD token that blocks the payout wallet, and recovery after
those failures. Repeated buy/sell cycles check that a trader cannot create ETH or
retain tokens through a round trip. A deterministic action sequence exercises
every handler selector and crosses the surcharge expiry.

`MoneyBackTokenLedger.t.sol` tracks each of four holders' expected balance and all
16 allowances. Transfers, self-transfers, full-balance transfers, approvals,
revocations and delegated transfers run in random order. Rejected calls check
exact errors and full rollback, including allowance consumption before a failed
transfer. This is stronger than supply conservation alone.

All existing invariant suites now fail on unexpected handler reverts. The payout
handler's replay check was corrected to expect `EnforcedPause` while paused and
`RoundAlreadyPaid` otherwise; previously that harness error could be ignored by
the runner.

## Reproduction

No installation, RPC, environment mutation or network access is required:

```sh
forge build
forge test
```

To keep generated build artifacts within the assignment's scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The new real-manager suites use 256 invariant runs at depth 64 and 1,000 fuzz
cases per round-trip test. The token ledger uses 256 runs at depth 80. Inline
settings for inherited real-manager tests are attached to the concrete test
contracts, where Foundry applies them. All new invariant handlers enforce
`fail-on-revert = true`; expected failures are caught and checked explicitly.

## Scope

This is offline integration coverage, not a Robinhood Chain fork or a deployment
rehearsal. IMD's live transfer behavior, factory allocation and live public-pool
liquidity are not recreated by the mock. The existing single-sided opening-price
and first-buy tests remain in `MoneyBackRealV4.t.sol`.

The authorized two-phase deployment is preserved: the factory launches token and
hook; the requester separately deploys the payout and router. Hook fees remain
IMD and sweep to the immutable paying wallet. RoundPayout funding remains an
explicit wallet action. These tests do not treat the auxiliaries' absence from
the factory deployment as a defect.

## Local validation

With Forge 1.7.1 and Solidity 0.8.26 (the repository's Cancun target),
`forge build` succeeded and the full suite passed **266 tests across 10 suites,
with zero failures and zero skips**. The run used the scratch output/cache paths
shown above. All 20 invariant tests reported zero handler reverts. The two new
real-manager suites each exercised every selected handler action; their inherited
round-trip tests each ran 1,000 fuzz cases. No new production defect was reproduced.
