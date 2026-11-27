# Homing

**Every wallet finds its way home.**

Register your wallets across chains. If a sweepable wallet goes quiet for too long, Homing warns you, then sweeps its tokens back to your main wallet — automatically, with no server and no custody, powered by Reactive Network.

Built for the Reactive Omni Buildathon (Track 2).

## The problem

People end up with many wallets: one per chain, one per airdrop, one from an old exchange. Some get forgotten with tokens still inside. Today the only fix is to remember — or to hand your keys to someone else.

## How it works

1. **Register.** Each wallet registers itself in the `WalletRegistry` on Sepolia with a tag: `0` primary (proves you're alive, receives sweeps), `1` cold (never swept), `2` sweepable.
2. **Watch.** `HomingReactive` on Reactive Lasna hears `WalletAdded` and **dynamically subscribes** to that wallet's outgoing ERC-20 transfers on **Ethereum Sepolia and Base Sepolia**. Any transfer = the owner is still around → `onActivity` callback to the vault.
3. **Bring home.** A Cron100 clock (~2 min) checks idle time. When a sweepable wallet passes the limit, Reactive sends `onSweep`. The `Vault` **re-checks the deadline itself** (user's own wait + grace period) and only then moves the approved tokens to the primary wallet.

```
Sepolia / Base Sepolia                Reactive Lasna                    Sepolia
WalletRegistry ── WalletAdded ──▶ HomingReactive ── subscribe ──▶ wallet Transfer events
wallet Transfer ─────────────────▶   react()    ── onActivity ──▶ Vault (lastActivity)
Cron100 tick ────────────────────▶   react()    ── onSweep ─────▶ Vault (re-check → transferFrom)
```

## Proof: first real sweep on testnet (2026-11-27)

| Step | Transaction |
|---|---|
| Primary wallet sends HMT → Reactive → **`onActivity` callback** delivered to Vault | [`0x5df95bf1…bb0a`](https://sepolia.etherscan.io/tx/0x5df95bf1bcae5d900885b926a79428f6177fa2a7d7c7043467a27efb4cc2bb0a) |
| Forgotten wallet idle > 5 min → Cron tick → **`onSweep` callback** → 101 HMT moved home | [`0x4178d159…9b46`](https://sepolia.etherscan.io/tx/0x4178d15939d1ab3ef67ea8fcf6560d35ac930ffdbcfa6d27ad29584b20669b46) |
| Reactive contract (all `react()` executions) | [Reactscan](https://lasna.reactscan.net/address/0x80c1346fcc786077BBef753d560594803fBc8fa7) |
| Forgotten wallet: 100 HMT in, 101 HMT out | [Token transfers](https://sepolia.etherscan.io/address/0xF5A5eD57bA8B57B1BB61ADB6370606A3F71a86D7#tokentxns) |

## Why Reactive

- **No server, no keeper bot.** Watching many wallets across chains and acting on silence needs something that is always on. Reactive contracts are.
- **Cross-chain by default.** One contract watches Sepolia and Base Sepolia and acts on Sepolia.
- **Event-driven cost.** Activity is pushed to us as events; we don't poll balances. The clock is capped (auto-unsubscribes after N ticks).

## Safety design

- **Non-custodial.** Tokens stay in the user's wallets. The vault only holds ERC-20 approvals and only sends to the owner's own primary wallet.
- **Double check.** Reactive decides *when to ask*; the vault decides *whether to act*, using its own on-chain data. Not yet due → `SweepSkipped`, no revert, no funds moved.
- **Only our Reactive contract can call the vault** (`onlyServiceProvider` + `onlyCallbackSender`).
- **Changing the sweep target or heir is delayed** (`CHANGE_DELAY`), so it can't be swapped at the last minute.
- **Runaway-cost limits:** max 20 wallets, capped clock ticks, throttled `onActivity`, retry interval for sweep requests.
- Inheritance (`claim()`): if *all* wallets stay silent past `inheritPeriod`, the heir can claim. The vault checks this itself — no callbacks needed once the owner is gone.

## Architecture & team

| Part | Chain | Owner | File |
|---|---|---|---|
| WalletRegistry | Ethereum Sepolia | bee | `contracts/homing/src/WalletRegistry.sol` |
| Vault | Ethereum Sepolia | bee | `contracts/homing/src/Vault.sol` |
| HomingReactive | Reactive Lasna | Yilin | `contracts/homing/src/HomingReactive.sol` |
| Shared interface | — | all | `contracts/homing/src/IHoming.sol` |
| Web app | — | 方瑜 | `frontend/` |

## Deployments (testnet)

| Contract | Chain | Address |
|---|---|---|
| WalletRegistry | Sepolia | `0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6` |
| HomingReactive | Lasna | `0x80c1346fcc786077BBef753d560594803fBc8fa7` |
| Vault | Sepolia | `0x8F40597510bdC7f89832189cC3e233ff9942A8B9` |
| HomeToken (HMT, demo) | Sepolia | `0x0db140Bb118A264C0E221d75f49aFb1db9C28660` |

Demo settings: idle 300 s, vault wait 240 s + grace 60 s, clock 30 ticks.

## Run it yourself

```bash
cd contracts/homing
forge install foundry-rs/forge-std Reactive-Network/reactive-lib-omni --no-git
forge test                      # 38 tests: Reactive, Vault, failure paths, end-to-end
bash script/deploy.sh           # deploy all (needs PRIVATE_KEY in .env, lREACT + Sepolia ETH)
bash script/demo.sh             # register a forgotten wallet and watch it come home
```

## Limitations (MVP)

- Only ERC-20 transfers count as activity; native ETH transfers emit no event.
- Each token must be approved to the vault once per wallet.
- Wallets register in the registry and link in the vault (two steps; the web app does both).
- EVM chains supported by Reactive only. Sweeps happen on Sepolia in this MVP.
