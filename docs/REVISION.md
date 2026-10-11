# Revision: one IMD fee base and accurate payout failures

This revision addresses the reopened review without changing fee constants, permissions, ownership, supply allocation or the deployment sequence. Every supplied finding has a disposition in [`.imd-responses.json`](../.imd-responses.json). The [earlier audit response](AUDIT_RESPONSES.md) is retained as historical evidence; its fee formulas, test totals and runtime sizes are superseded here.

## Reproductions and fixes

### Fee base — 9349b4cd221d

The unchanged supplied fee proof failed both tests on the starting tree: an exact-output seller paid less hook fee than an equivalent exact-input seller, and the rate on the gross pool output was 1951 bps instead of 2425 bps at initialization.

All four swap forms now price the actual pool-side IMD leg. For specified IMD, let `A = abs(amountSpecified)` and `r = 425 + currentSurchargeBps` on sells:

| Swap form | Hook fee F | Pool IMD leg P |
| --- | --- | --- |
| Exact-input buy | `floor(A * 425 / 10425)` | `A - F` |
| Exact-output sell | `ceil(A * r / (10000 - r))` | `A + F` |
| Exact-output buy | `floor(P * 425 / 10000)` | Observed pool input |
| Exact-input sell | `floor(P * 425 / 10000) + floor(P * surchargeBps / 10000)` | Observed pool output |

The buy inversion rounds down to avoid consuming an entire tiny input as a fee. The sell inversion rounds up to cover the rate on the gross pool output while preserving the exact net output requested. Compared with separately flooring both components on P, the difference is at most one IMD wei on buys and two on sells. With an active sell surcharge, the event's base component remains floored on P and its surcharge component includes the rounding remainder. With no surcharge, the entire fee is base fee. These are raw 18-decimal token units, not basis-point differences.

`FeeAccrued.imdLeg` reports P in every case. The existing `afterSwap` full-fill check uses the same inversion as `beforeSwap`, so a specified-IMD underfill still reverts atomically. Specified and gross pool amounts must fit positive int128; the checks precede minting. No transient slot, external fee conversion, new permission or admin function was added.

The unchanged supplied proof now passes both tests. Delivered `MoneyBackRealV4.t.sol` tests compare identical MONEYBACK movement from identical pool state in both swap forms, with either asset ordering, at 0/900/1799/1800/3600 seconds and over fuzzed amounts/timestamps. They independently check the observed pool leg and bounded rounding, plus claim redemption and tight-limit/exhausted-liquidity rollback. The mock suites retain callback, event, tiny-amount, no-MONEYBACK-fee and fee-conservation coverage with corrected expectations. New boundary tests cover valid int128-sized legs and gross-output overflow without minting.

### Failed-recipient counter — dc69946c1bd0

A scratch reproduction used recipients `[A,A,B]`, amounts `[3,4,1]`, and a token that rejected A. On the starting tree, retry paid the aggregate 7 and cleared `failed(1,A)`, but `failedCount` stayed at 1.

The counter now tracks distinct recipients with nonzero debt, matching the mapping that retry and write-off clear. Failed zero-amount legs still emit `PayFailed` but create no outstanding recipient. A separate success flag preserves `AllTransfersFailed` even if all failures are for the same recipient. A successful zero-amount transfer continues to count as a success.

Delivered tests cover retry while still blocked, successful aggregate retry, aggregate write-off, duplicate all-failure rollback, zero-value failures and successes, and conservation of funded tokens. The existing stateful invariant now requires exact equality between `failedCount` and the outstanding-recipient ledger; it no longer tolerates a stale counter.

### Router partial-fill documentation — 14b0855f1ab2

A real-manager reproduction confirmed that a small buy quotes successfully, while an oversized buy and quote both revert with `WrappedError(hook, afterSwap, PartialFill, HookCallFailed)`. The behavior is retained: both legs roll back when the launch buy cannot fill.

The NatSpec now distinguishes zero-output simulations from propagated errors and explains the full-fill requirement. The unreachable launch-buy IMD refund branch was removed. Existing ETH refunds on buys and MONEYBACK/IMD refunds on sells remain. Real-v4 regression tests in both currency orders assert the exact error, unchanged pool prices/balances/claims and a successful trade after rejection.

## Other reports

The supplied earlier partial-fill proof passed both tests on the starting tree and still passes. Its source was copied unchanged to scratch; a minimal scratch-only assertion shim resolved its unavailable `forge-std/Test.sol` import. Both provided proof copies were byte-compared with the pinned inputs, then removed from scratch before the ordinary project checks. They were not altered or submitted as replacements for verifier proofs.

The earlier router payer, unsupported manifest `contracts` field and stale payout comments were already repaired in the accepted tree. Current source and tests confirm caller-prefunding, settlement from router-held funds, the separate auxiliary deployment path, and sweep only to the immutable paying wallet. The deployment script and its six tests are unchanged.

The following reported behavior remains intentional and documented:

- Flags `0x20CC` do not include liquidity callbacks. The real-v4 LP-conversion regression passes in both currency orders; adding/removing positions is outside the swap surcharge.
- RoundPayout's owner can choose recipients and amounts, sweep while paused, pause/unpause, retry, write off, transfer ownership and renounce. A funded renunciation test confirms the resulting permanent inability to sweep; no restriction was added to the owner's permitted powers.
- The ownerless router cannot recover directly transferred ERC-20s. Forced ETH goes to the next successful trader. Tests preserve token gifts across trades/quotes and model forced ETH with `vm.deal`; ordinary ETH sends are separately tested to revert. The header and README now state these limits.
- IMD and the public ETH/IMD pool key remain specific to the requested Robinhood Chain launch. The PoolManager remains a constructor argument. Prior network observations are historical; no live RPC observation is claimed for this revision.

## Validation

Run on 2026-10-12 JST with Forge 1.8.3 and the unchanged Solidity 0.8.26/Cancun configuration:

| Check | Result |
| --- | --- |
| Supplied fee proof, before repair | 2 failed as reported |
| Supplied fee proof, after repair | 2 passed |
| Supplied partial-fill proof, before and after | 2 passed each time |
| `forge build` | Exit 0 |
| `forge test` | Exit 0; 231 passed, 0 failed, 0 skipped across 7 suites |
| `forge fmt --check` | Exit 0 |
| `imd launch check .` | Exit 0; manifest passes against this build; Slither runs only on the verifier |
| `git diff --check` | Exit 0 |

The ordinary suite requires no environment variables, RPC, downloads, FFI or filesystem permissions. It includes unit, fuzz, invariant and real-v4 tests. Scratch assertion scaffolding is not needed for the delivered tests. No dependency or protected build configuration was changed, and no package was installed.

Production runtimes are MoneyBackToken 1,575 bytes, MoneyBackHook 6,478 bytes, RoundPayout 5,566 bytes and MoneyBackRouter 6,979 bytes. All are below EIP-170; artifacts contain no unresolved library links. A PUSH-aware runtime scan found no SELFDESTRUCT, DELEGATECALL or CALLCODE in the four contracts. Foundry reports lint warnings; the build is not described as warning-free.

`slither . --compile-force-framework foundry` was attempted and returned exit 127 because Slither is unavailable. The external protected harness, live-chain fork, Mythril, formal verification and independent post-repair audit were not run here. Local checks do not replace the verifier or independent release review.

## Deployment and operations

The existing README remains the parameter and operations guide. The hook's bytecode changed, so the authorized deployer must mine a fresh CREATE2 salt against the final bytecode and resolved arguments. The launch still uses 425 base bps, 2000 sell surcharge bps decaying over 1800 seconds, flags `0x20CC`, LP fee 12500, tick spacing 60, and immutable payout `$owner`. Fees stay in IMD claims until permissionless sweep sends IMD to that wallet.

The factory's 10% swarm / 81% single-sided pool / 9% dead-address split is unchanged. RoundPayout and MoneyBackRouter still require the documented auxiliary deployment after the token and hook; their receipts must be recorded before claiming a four-contract launch. The paying wallet must fund RoundPayout explicitly and operate its off-chain engine. This revision makes no network transactions or deployment-completion claim.
