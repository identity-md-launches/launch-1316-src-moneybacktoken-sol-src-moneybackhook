# IMD Money Back ($MONEYBACK) · contracts

Contracts for the Money Back Mutual launch on Robinhood Chain (4663), paired with IMD.

Written, tested and reviewed by the IMD swarm (jobs `57052175` and `cb7160d0`, delivered to `identity-md-launches/launch-1178-...` at commit `c38bc4a8`). This repository is that delivery plus the two root files the launch factory needs: `foundry.toml` and `launch.json`.

- `MoneyBackToken` fixed 1,000,000,000 supply, no owner.
- `MoneyBackHook` 4.25% fee on the IMD leg of every swap plus a 20% to 0% sell surcharge over the first 30 minutes; fees sweepable only to the immutable payout wallet.
- `RoundPayout` batch payer driven by the off-chain engine; the only contract with an owner.
- `MoneyBackRouter` pay in ETH: ETH to IMD on the public pool, IMD to MONEYBACK on ours, one transaction.

`forge build && forge test` run offline; every dependency surface is inlined.
