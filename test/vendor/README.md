# Offline integration-test dependencies

These ordinary source files support tests only; no production contract imports them.

- Uniswap v4-core, commit `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`: https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75. Included: PoolManager, StateLibrary and their transitive source imports, with upstream licenses.
- Solmate Owned, commit `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pinned submodule): https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647. Included as files with its license, not a submodule.

The sole import-path change replaces ProtocolFees.sol's solmate package import with a relative path. Solidity whitespace is formatted with this project's forge fmt. No remappings, protected dependencies or build configuration are changed. No network is used by the delivered tests.
