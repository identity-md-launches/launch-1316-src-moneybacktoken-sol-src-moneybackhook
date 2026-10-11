# Imported audit: reproductions and repairs

This is the implementation response to the eight supplied entries, not a new independent audit. Production changes are limited to the partial-fill guard, router funding/settlement, and associated comments. Fee constants, permission flags, token and RoundPayout logic remain unchanged.

## 1. Partial-fill overcharge — reproduced and fixed

**ID:** `baaef0a96e278932ef3e0a642322378aaa3387fe542403b5e811b7ede07910f1`

The supplied proof was adapted only to replace its unavailable forge-std assertion base with equivalent local assertions. Both tests failed against the original source: exact-input buy charged above the filled leg; exact-output sell made the seller pay IMD. They pass after repair.

`afterSwap` now requires the signed IMD pool delta to equal the original specified amount plus the separately floored fee for IMD-specified swaps. Otherwise it reverts `PartialFill`, undoing pool movement, claims and settlement. All four full-fill fee formulas remain unchanged. IMD-unspecified cases still charge actual movement and allow partial fills. No shared transient slot is necessary: the fee uses constants and a block timestamp that cannot change between the two callbacks.

Delivered evidence: `MoneyBackRealV4.t.sol` runs against the actual v4-core PoolManager with token as each currency. It checks tight-limit and exhausted-liquidity reverts with the precise wrapped `PartialFill` error, unchanged balances/claims/pool price, allowed partial IMD-unspecified trades, full-fill fees at 0/900/1800 seconds, and first trades in a pool with zero initial IMD. `MoneyBackHook.t.sol` also fuzzes one-wei underfills and checks a zero-fee rounding case. Router tests require both legs and claims to roll back on partial launch buys.

## 2. Router callback payer — pattern reproduced and fixed; Slither unavailable

**ID:** `85246a65512a834ff193811a72d781bf291afb891afa9360a318b9d03eb7228b`

The original `_sell` called `transferFrom(d.user, manager, amount)` using callback-decoded data. Source inspection confirms the reported pattern; the existing callback digest and manager gates prevented arbitrary third-party use. The repair moves `transferFrom(msg.sender, address(this), tokens)` to `sellForEth` before unlock. The callback settles the consumed amount with `sync -> transfer -> settle` from the router's balance; the entry point refunds unused MONEYBACK directly to the caller.

Delivered evidence: `test_sellPrefundsRouterThenSettlesAndRefundsFromItsOwnBalance` inspects the three real ERC-20 transfer events, including the full prefund and partial-fill refund. Existing unauthorized payer, allowance, callback spoofing, slippage, deadline and reentrancy tests remain. The real-v4 router integration buys, sells partially and ends with no router balances or unsettled deltas.

Attempted `slither . --compile-force-framework foundry`; exit 127, `/bin/bash: line 1: slither: command not found`. Therefore neither the original detector output nor a clean post-repair Slither report is claimed locally. The verifier still needs to run Slither. The existing ETH refund-to-caller behavior remains intentional.

## 3. Unsupported manifest auxiliary list — reproduced and repaired with separate deployment

**ID:** `d0c5e4ca336220c394907f7c7dafcea0ea8a8d317d1c7293bc58ceb4226235fb`

Read the installed IMD worker `v0.1.0+40b9e587` protocol definitions. `UniV4HookManifest` accepts `kind`, `token`, `hook`, `pool`, `notes`; its `manifestContracts` selects only token and hook. Unknown fields are stripped. Indeed the original manifest passed `imd launch check .` despite its ineffective `contracts` array. A passing check alone did not mean four deployments.

The final manifest removes the unsupported array and resolver, and states the two-phase deployment explicitly. `DeployAuxiliaries.s.sol` accepts the actual manager and mined hook as arguments, validates them, and deploys RoundPayout with the brief's paying wallet as owner and MoneyBackRouter with the real hook. Six tests cover correct deployment/ownership and refusal of wrong chain, missing deployments, wrong manager, wrong payout and uninitialized hook. The script's callable deployment function shares the same creation logic as its Foundry entry point.

Requester-share economics similarly belong to the launch task, not this hook manifest. `docs/requester-share.json` preserves the installed `RequesterShare` shape (`poolBps`, `remainderTo`). The README and manifest notes state 10% swarm, 81% single-sided pool and 9% dead-address remainder. The network's launch service must carry those inputs and verify receipts. Neither auxiliary has a launch-token allocation.

Remaining execution responsibility: the authorized deployment process must actually deploy both auxiliaries after the factory launch and record their receipts. No unsupported automatic deployment is claimed.

## 4. Single-sided LP conversion — reproduced; retained constraint documented

**ID:** `4cb54ff2b8ceec710e5b91ad765ac2b2a356acf3d2a53f153794acc7ce9f99ec`

`test_liquidityConversionIsOutsideSwapSurcharge` runs on real v4 in both currency orders: add a MONEYBACK-only position across ticks 60/120 (mirrored for the reverse ordering), buy through it, and remove IMD with no MONEYBACK left. The buyer pays its 4.25% hook fee; neither LP operation changes pending claims, while the sell surcharge remains 2000 bps.

This is not falsely reported as fixed. The brief fixes flags at `0x20CC`, which excludes liquidity callbacks. Adding a restriction would change those explicit requirements. The README and manifest notes explain that the surcharge applies to this pool's swaps and is not a guarantee on LP conversions or every economic sale. No owner or restriction was added.

## 5. Stale sweep destination comments — reproduced and fixed

**ID:** `46a32fa88879b5ac9b5942c6b16cf98506d35309d4a1de495ca558f275c0d829`

The hook's header, immutable field and constructor comments incorrectly called the payout RoundPayout, although `$owner` selects the paying wallet. All three comments now agree with the brief and manifest. Sweep destination semantics are unchanged. Hook sweep tests and the auxiliary deployment test verify the fixed wallet. Documentation explains the separate approval and `fund(IMD, amount)` operation required before the engine can pay rounds.

## 6. RoundPayout powers — confirmed intended trust assumption

**ID:** `c200319894a167787f522936e073af7f867bf49c05157c30d8d0553f51980f02`

Source review and the existing RoundPayout suite confirm owner-directed payments, unrestricted owner sweep of payer-held tokens (including while paused), pause/unpause, retry, write-off and two-step ownership. These are the privileges the brief permits; no defect or repair is invented. The original contract and test file are unchanged. The README makes manual funding, discretionary off-chain eligibility, owner powers and engine duties explicit. No holder balances can be confiscated by these functions.

## 7. Chain-specific IMD and public route — confirmed for the requested chain

**ID:** `c0c14411f2d25d5ec04d8761a7de039000b1350eeca0e570ba549d2e05bde0fe`

The paired IMD address and public ETH/IMD pool key remain fixed as required. Read-only RPC calls on chain 4663 at block **85,912,608**, hash `0x673cd8ee41179c836decdcdb2e5200cd40fc9eb69caef04a62ba293bd166b218`, confirmed nonempty code at IMD and the audit-supplied observed PoolManager, `symbol() == IMD`, `decimals() == 18`, and a nonzero public-pool sqrt price with LP fee 10000 and active liquidity. Exact responses and code hashes are in `network-observations.json`. The production manager remains an argument resolved as `$poolManager`; the observed address is not a deployment default.

A local fork at that same block also passed an ETH buy, ETH sell, state-neutral quotes and an IMD sweep to the actual paying wallet using the live IMD, manager and public pool. MONEYBACK and its hook/router were deployed only inside the fork; a temporary MONEYBACK-only test pool used a 1:1 price and test liquidity. No transaction was sent to Robinhood Chain. This establishes route compatibility at the pinned state, not future liquidity or a rehearsal of the actual factory and policy opening position.

## 8. Coverage — updated; prior contributor checks not inherited

**ID:** `d1d0fa0e5bd170a2f6aa5ae3b21af0612f889633cdd3c37eedb6448d83900e13`

Read the four production sources, manifest and build configuration, supplied hook/token floor tests, security/address/L2 references, the imported proof and relevant original test fixtures and failure cases. Reviewed real v4's hook delta flow and settlement code. Added and inspected the real-manager, auxiliary deployment and regression tests.

Local execution:

- Original source: **183 tests passed**. The separate imported partial-fill proof then produced **two expected failures** before repair.
- Final delivered source: see the final validation record below. Its tests run without network and include existing fuzz/invariant suites plus both currency orderings against real v4-core.
- Additional local fork: **one targeted route test passed** at block 85,912,608 using the actual external contracts. The RPC-dependent scratch test is excluded from the offline deliverable.
- Logo: generated SVG rendered with the installed sandboxed Chromium, visually inspected; ffprobe confirmed PNG, 1024 × 1024, RGB24.
- Real installed IMD manifest check is run against the final build; own JSON assertions are not treated as protocol validation.

Limits: the external verifier's protected floor harness was read but not executed unchanged locally; it owns the attested creation-code probes. Equivalent initialization, permissions, callback refusal, supply and transfer behavior is exercised by delivered tests. Slither is unavailable here; Mythril and formal verification were not run. The actual launch factory's allocation/LP receipt path, final mined deployment addresses, independent post-repair review, explorer verification, website publication and funded engine operation belong to the release process and are not claimed complete by these local checks. No other panelists or repositories were consulted to claim inherited coverage.

## Final validation record

Validated on 2026-10-11 using Forge 1.8.3 and the unchanged Solidity 0.8.26 configuration:

| Check | Observed result |
| --- | --- |
| `forge build` | Exit 0 |
| `forge test` | Exit 0; **216 passed, 0 failed, 0 skipped** across 7 suites |
| `forge fmt --check` | Exit 0 |
| `imd launch check .` | Exit 0; `launch.json passes the launch check against this build. Slither runs only on the verifier.` |
| `git diff --check` | Exit 0 |
| Protected configuration / original token and payer | No diff |
| Local pinned-chain route test | 1 passed, 0 failed; no broadcast |

Compiled production runtime sizes: MoneyBackToken **1,575** bytes; MoneyBackHook **6,183**; RoundPayout **5,506**; MoneyBackRouter **6,983**. All are below EIP-170's 24,576-byte limit. Compiled artifacts have no unresolved library links; a PUSH-aware runtime scan found no SELFDESTRUCT, DELEGATECALL or CALLCODE in any of the four contracts. This scan and the local checks do not replace the external verifier or final independent review.

The build reports Foundry lint warnings, including explicit integer casts and timestamp reads around test cheatcodes; it is not represented as warning-free. Scratch RPC tests/logs and generated build outputs are excluded from source changes. The delivered source keeps its offline test dependencies and both required logo formats.
