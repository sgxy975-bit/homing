# Homing

**Every wallet finds its way home.** Register your wallets across chains. If a sweepable wallet goes quiet for too long, Homing warns you, then sweeps its tokens back to your main wallet — automatically, via Reactive Network.

Built for the Reactive Omni Buildathon.

## Architecture

| Part | Chain | Owner | Folder |
|---|---|---|---|
| WalletRegistry — emits `WalletAdded(wallet, owner, tag)` | Ethereum Sepolia | bee | `contracts/homing/src/WalletRegistry.sol` |
| Vault — `onActivity` / `onSweep` callbacks, re-checks deadlines, sweeps; inheritance `claim()` | Ethereum Sepolia | bee | `contracts/homing/src/Vault.sol` |
| HomingReactive — watches wallets on Sepolia + Base Sepolia, decides when to sweep | Reactive Lasna | Yilin | `contracts/homing/src/HomingReactive.sol` |
| Web app | — | 方瑜 | `frontend` |

Shared interface: [`contracts/homing/src/IHoming.sol`](contracts/homing/src/IHoming.sol). Change it only after telling the team.

## Deployments (testnet)

| Contract | Chain | Address |
|---|---|---|
| Registry | Sepolia | `0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6` |
| HomingReactive | Lasna | `0x80c1346fcc786077BBef753d560594803fBc8fa7` |
| Vault | Sepolia | `0x8F40597510bdC7f89832189cC3e233ff9942A8B9` |
| HomeToken (HMT, demo) | Sepolia | `0x0db140Bb118A264C0E221d75f49aFb1db9C28660` |

## Run the tests (38: Reactive, Vault, failure paths, end-to-end)

```bash
cd contracts/homing
forge install foundry-rs/forge-std Reactive-Network/reactive-lib-omni --no-git
forge test
```
