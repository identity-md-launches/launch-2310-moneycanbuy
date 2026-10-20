# moneycanbuy (YOLO)

A plain, fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum.

| Field | Value |
| --- | --- |
| Solidity contract | `YoloToken` (`src/YoloToken.sol`) |
| Token name | `moneycanbuy` |
| Symbol | `YOLO` |
| Decimals | 18 |
| Total supply | 1,000,000,000 YOLO = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## What it does

"yolo": the token does one thing and nothing else. The whole supply is minted once, in the
constructor, to the deployer (`msg.sender`). After that:

- `transfer`, `approve`, `transferFrom` behave exactly as ERC-20 specifies. Every transfer moves
  exactly the requested amount. There is no tax, fee, reflection, cooldown, max-wallet or
  max-transaction rule.
- `increaseAllowance` / `decreaseAllowance` are provided to avoid the approve race. An allowance of
  `type(uint256).max` is treated as unlimited and is not decremented.
- `burn(amount)` lets a holder destroy their own tokens. `burnFrom(from, amount)` does the same
  using an allowance the holder explicitly granted. Burning is the only way the supply ever changes,
  and it can only shrink.
- Transfers and approvals to the zero address revert with `ZeroAddress()`. Use `burn` instead.
- Failures revert with typed errors: `InsufficientBalance(sender, balance, needed)`,
  `InsufficientAllowance(spender, allowed, needed)`, `ZeroAddress()`.

There is no owner, no `mint`, no pause, no blocklist, no freeze, no seize, no upgrade path, and the
runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Nobody, including the deployer,
can move or lock a holder's balance or grow the supply.

## Assumptions

- The requester's brief ("yolo") asks for no transfer rules, so none were added. If taxes, vesting,
  reflections or governance are wanted, that is a different token and should be ordered as such.
- The deployer at launch is the IdentityMD ProjectFactory. The constructor mints the entire supply
  to it and the factory distributes it (10% to the swarm's MerkleDistributor, 60% to seed the
  Uniswap v4 pool, 30% to the requester's `remainderTo` address). Because the token has no fee or
  exemption logic, it needs none of the launch addresses as constructor arguments.
- The contract is self-contained. It imports nothing, so no third-party token library is vendored.
  `forge-std` (v1.11.0, MIT/Apache-2.0) is vendored under `lib/forge-std` as plain files for tests
  only.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet (chain id 1) |
| Contract to deploy | `YoloToken` |
| Constructor arguments | none |
| `token.totalSupply` for the manifest | `1000000000000000000000000000` |
| `token.decimals` for the manifest | `18` |
| Pool pair | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Pool fee / tick spacing | 12500 (1.25%) / 60 |
| Economics | `poolBps` 6000, `initialMarketCapWei` 2500 IMD, `remainderTo` `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` |

The pool price is derived by the launch deployer from the market cap and the token's address. No
`launch.json` is written here; the manifest step writes it after acceptance.

## After launch

Nothing to configure. The token has no owner-settable values and no post-deploy calls. The only
operational responsibilities are:

- **Explorer verification** of `YoloToken` source, by the network's deployer (`forge verify-contract`
  with solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`, `cbor_metadata = false`).
- **Allowance hygiene** for integrators: approve exact amounts, or use `increaseAllowance` /
  `decreaseAllowance` when adjusting a live allowance.
- **Burns are irreversible.** Holders who call `burn` destroy their own tokens permanently.

## Building and testing

```bash
forge build
forge test
forge fmt --check
```

Tests live in `test/YoloToken.t.sol` and cover metadata, the one-time mint to the deployer,
exact-amount transfers (including chained transfers arriving whole), allowance semantics including
the unlimited-allowance case, burn and burnFrom, every revert path with its typed error, the
absence of admin selectors, the deployer's inability to move a holder's balance, an opcode scan of
the runtime, and fuzzed conservation-of-supply properties. Tests read no environment variables and
pass in any order and in parallel.

## Security notes

Tests passing is not an audit. The contract is small and has no privileged surface, external
calls, or arithmetic beyond balance bookkeeping, which keeps the attack surface to standard ERC-20
semantics. Known ERC-20 caveats that apply to every token of this shape:

- The `approve` race: changing a non-zero allowance to another non-zero value lets a fast spender
  use both. Mitigated by `increaseAllowance` / `decreaseAllowance`.
- Tokens sent to a contract that cannot handle them are stuck. The token does not implement
  ERC-777 hooks or ERC-1363 callbacks by design.

Tools run on this work: `forge build`, `forge test` (256 fuzz runs per property, including with the
verifier's pinned seed), `forge fmt --check`. Slither and Mythril were not available in this
environment and were not run.
