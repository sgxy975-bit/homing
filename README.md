<p align="center"><img src="assets/homing-logo-cream.png" alt="Homing" width="420"></p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">中文</a></p>

# Homing

**Like a homing pigeon: forgotten money always finds its way home.**

> **Homing** watches over all your wallets, across chains. When one wallet is forgotten, you get a reminder first; if you don't respond, its tokens are moved back to the wallet you actually use. If every wallet goes silent for a very long time, your heir can claim what's left. The rules run on-chain through Reactive Network.

[![Reactive Network](https://img.shields.io/badge/Reactive_Network-Lasna-F05C00?style=for-the-badge)](https://dev.reactive.network)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.29-363636?style=for-the-badge&logo=solidity)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Foundry-44_tests_passing-1C1C1E?style=for-the-badge)](https://getfoundry.sh)
[![Testnet](https://img.shields.io/badge/Sepolia_%2B_Base_Sepolia-testnet-627EEA?style=for-the-badge&logo=ethereum)](https://sepolia.etherscan.io/address/0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4)

Reactive Omni Buildathon · Track 2 (Set It and Forget It)

Live demo: [open the web app](https://htmlpreview.github.io/?https://github.com/sgxy975-bit/homing/blob/main/frontend/index.html) · On-chain proof below

---

## 🎯 The problem

- **Target user:** **Lin**, three years into crypto, with seven or eight wallets: one for daily use, several for airdrops, a few made just to test projects.
- **The problem:** Small balances sit forgotten in the old wallets. And if something happens to Lin, the family doesn't even know those wallets exist — the money is gone for good.
- **Today's tools each solve one piece:**
  - **Casa, Vault12**: "If I never come back, my family can't reach my crypto." Multisig keys or trusted guardians hold key shares, so family can recover the wallet.
  - **Ledger Recover**: "I might lose my seed phrase." An encrypted seed backup split across several companies.
  - **Sarcophagus**: If you stop checking in, an encrypted file (such as a seed phrase) is released to someone you chose.
  - **BitGo, Ripple Custody**: "Thousands of deposit addresses need sweeping." Scheduled sweeping for exchanges and businesses, but the funds are held in custody.

  They either act only after you're gone, or ask you to hand over keys or assets. None of them sweep forgotten wallets for you while you're still here.
- **Homing's answer:**
  1. **Register once.** Each wallet signs its own registration and gets a tag: primary, cold or sweepable.
  2. **Keep watching.** A Reactive contract follows every wallet's transfers on every chain. Any activity means you're still around.
  3. **Forgotten? Bring it home.** A wallet quiet for too long gets a reminder → grace period → tokens back to your primary wallet.
  4. **Gone? Hand it to family.** When every wallet has gone silent, your heir can claim.

---

## 📱 How it works

You register your wallets once. Then Homing escalates step by step — and any activity from any registered wallet resets the clock.

| Situation | What Homing does |
| --- | --- |
| All wallets active | Nothing |
| One wallet silent for a while (e.g. 6 months) | Reminder → grace period → tokens swept to your primary wallet |
| **All** wallets silent for a long time (e.g. 3 years) | Your heir can claim the funds (cold wallets only if you opted in) |

| Tag | What it means |
| --- | --- |
| **Primary** | Your daily wallet. Its activity proves you're still here, and it receives the sweeps. |
| **Cold** | Never swept. Only joins inheritance, and only if you opt in. |
| **Sweepable** | Brought home after a reminder and grace period. |

---

## ⛓️ It works on testnet

On 2026-11-27 we ran both halves end to end with real transactions: a forgotten wallet came home on its own, and an heir claimed the funds of an owner whose wallets had all gone silent.

| Step | Transaction |
| --- | --- |
| Primary wallet sends a token → Reactive sees it → **`onActivity`** callback updates the vault | [`0x5df95bf1…bb0a`](https://sepolia.etherscan.io/tx/0x5df95bf1bcae5d900885b926a79428f6177fa2a7d7c7043467a27efb4cc2bb0a) (vault v1) |
| Forgotten wallet idle for 2 min → Reactive asks to sweep → **`onSweep`** callback → 100 HMT moved home | [`0xc7c86e6d…f81c`](https://sepolia.etherscan.io/tx/0xc7c86e6dd0e4ff604e7d2465db54c069353124bad027e474728a04a45f61f81c) |
| Heir tries too early → rejected (`StillActive`); after 10 min of silence → **`claim()`** → 70 HMT (primary 20 + cold 50) to the heir | [`0x177fc329…32af`](https://sepolia.etherscan.io/tx/0x177fc329a9f3eaa53092036de5c5f8182d16c9e9378a73303358ca71e45132af) |
| Every `react()` run of our Reactive contract | [Reactscan](https://lasna.reactscan.net/address/0x80c1346fcc786077BBef753d560594803fBc8fa7) |

**Built and running on testnet:** wallet registry, cross-chain activity tracking with dynamic subscriptions, half-time warning, grace period, automatic sweep with vault re-check, inheritance `claim()`, delayed config changes, and 44 tests (incl. failure paths, security regressions and an end-to-end test).

---

## ⚡ Why Reactive

- **Cross-chain by nature.** Your wallets live on several chains. One Reactive contract listens to all of them (Ethereum Sepolia and Base Sepolia today) and reports to the vault. Without Reactive we'd need our own always-on server.
- **Nothing to run.** Wallet activity arrives as events, and a capped clock checks for silence. No keeper bot, no backend.
- **Rules are public.** Every reminder and sweep follows rules written on-chain that anyone can check.

---

## 🛠️ Tech stack & architecture

```
 Ethereum Sepolia / Base Sepolia        Reactive Lasna                 Ethereum Sepolia
 WalletRegistry ── WalletAdded ───▶  HomingReactive  ─ subscribes to ─▶ that wallet's transfers
 a wallet sends tokens ───────────▶     react()      ── onActivity ──▶ Vault: "still alive"
 clock tick (Cron, ~2 min) ───────▶     react()      ── onSweep ─────▶ Vault: re-check → sweep
```

| Part | Where | Technology | What it does |
| --- | --- | --- | --- |
| **WalletRegistry** | Sepolia | Solidity 0.8.29 | Each wallet registers itself with an owner and a tag; emits `WalletAdded` |
| **HomingReactive** | Reactive Lasna | Solidity + Reactive Omni | Hears `WalletAdded` and subscribes to that wallet's token transfers on every watched chain (dynamic subscription). Tracks last-seen time, warns at half-time, asks the vault to sweep when time is up |
| **Vault** | Sepolia | Solidity 0.8.29 | Holds only token allowances. Re-checks the deadline with its own data before moving anything. Also handles inheritance (`claim()`) and delayed config changes |
| **Web app** | Browser | HTML / CSS / JS | Connect wallets, see everything in one place, register and approve, watch the countdown |
| **Tests & deploy** | Local | Foundry | 44 tests, one-command deploy and demo scripts |

Shared interface: [`contracts/homing/src/IHoming.sol`](contracts/homing/src/IHoming.sol).

---

## 🔒 Safety

- **Non-custodial.** Your tokens stay in your wallets. The vault only uses allowances you gave it, and you can revoke them anytime.
- **Two independent checks.** Reactive decides *when to ask*; the vault decides *whether to act*. If it's not really time yet, the vault skips — no revert, no money moved.
- **Only our Reactive contract can trigger a sweep** (Callback Proxy + sender check).
- **Nobody can claim your wallet.** Ownership comes from the registry: only the wallet itself can sign "I belong to you", so no one else can link it to their account. A wallet removed or re-tagged in the registry stops being swept at once, and an heir can't claim it.
- **Delayed changes.** Changing where sweeps go or who the heir is only takes effect after a waiting period, so nobody can swap it at the last minute.
- **Cost can't run away.** The demo contract watches at most 20 wallets in total, the clock stops itself after a set number of ticks, activity reports are throttled, sweep retries are spaced out.

---

## 🆚 How we're different

| Product | Type | How Homing differs |
| --- | --- | --- |
| Ripple Custody, BitGo ([Ripple](https://docs.ripple.com/products/wallet/changelogs/asset-sweeping-now-available)) | Scheduled sweeping for exchanges | For individuals; triggered by how long a wallet has been forgotten; non-custodial |
| Casa, Ledger Recover, Vault12 ([overview](https://chain.com/blog/who-inherits-your-wallet)) | Inheritance through keys | Hands over funds, never keys; also helps while you're alive |
| Sarcophagus ([comparison](https://www.spark.money/tools/crypto-estate-planning-comparison)) | Releases encrypted secrets after a deadline | Moves funds by rules instead of releasing secrets |

---

## 🚀 Quick start

```bash
cd contracts/homing
forge install foundry-rs/forge-std Reactive-Network/reactive-lib-omni --no-git
forge test                       # 44 tests
bash script/deploy.sh            # deploy everything (needs PRIVATE_KEY in .env, some lREACT and Sepolia ETH)
bash script/demo.sh              # sweep demo: watch a forgotten wallet come home in ~2 min
bash script/inherit_demo.sh      # inheritance demo: the heir claims after ~10 min
```

The web app needs no setup: open `frontend/index.html` in a browser.

---

## 📁 Project structure

```
contracts/homing/src/HomingReactive.sol   Reactive contract (Lasna)
contracts/homing/src/WalletRegistry.sol   Wallet registry (Sepolia)
contracts/homing/src/Vault.sol            Vault (Sepolia)
contracts/homing/src/IHoming.sol          Shared interface
contracts/homing/src/HomeToken.sol        Demo token HMT
contracts/homing/test/                    44 tests
contracts/homing/script/                  Deploy and demo scripts
frontend/index.html                       Web app (single file)
assets/                                   Logo
deployments.md                            Deployment record
```

---

## 📍 Deployments (testnet)

| Contract | Chain | Address |
| --- | --- | --- |
| WalletRegistry | Ethereum Sepolia | [`0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6`](https://sepolia.etherscan.io/address/0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6) |
| HomingReactive | Reactive Lasna | [`0x80c1346fcc786077BBef753d560594803fBc8fa7`](https://lasna.reactscan.net/address/0x80c1346fcc786077BBef753d560594803fBc8fa7) |
| Vault (v2, security fixes) | Ethereum Sepolia | [`0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4`](https://sepolia.etherscan.io/address/0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4) |
| HomeToken (HMT, demo token) | Ethereum Sepolia | [`0x0db140Bb118A264C0E221d75f49aFb1db9C28660`](https://sepolia.etherscan.io/address/0x0db140Bb118A264C0E221d75f49aFb1db9C28660) |

Demo settings: forgotten after 2 min (vault: 90 s wait + 30 s grace), inheritance after 10 min, clock runs 60 ticks (~2 h). Real use would be months and years. Vault v1 (`0x8F40…A8B9`) stays on-chain with the first sweep from 13:34.

---

## 🧭 Roadmap

These are planned but **not built yet**:

- 🛡️ **Guard mode**: when everything goes silent, freeze part and keep part in a conservative yield position with a stop-loss
- 🤖 **AI setup assistant**: suggests a freeze / yield split; you review and sign before anything goes on-chain
- 📨 **Email or Telegram reminders** (off-chain)
- ⛽ **Auto top-up of fees on both sides** (lREACT and ETH)
- 👛 **Create wallets inside the app and register them automatically**

**Plans (idea):**

| Plan | Includes |
| --- | --- |
| Free | Combined view and reminders, no Reactive |
| Pro | Automatic sweeps and automatic yield |
| Pro Max | Guard mode and inheritance |

---

## ⚠️ Limitations

- You have to register each wallet yourself; a wallet you never add can't be watched.
- Only token transfers count as activity — plain ETH transfers emit no event.
- Each token needs its own approval.
- EVM chains supported by Reactive only (no Bitcoin, Solana or exchange accounts). Sweeps happen on Sepolia in this MVP.
- Testnet only, not audited, and not a legal will.

---

## 👥 Team

| Name | Role |
| --- | --- |
| **Yilin** ([@sgxy975-bit](https://github.com/sgxy975-bit)) | Project lead · Reactive contract · integration & deployment |
| **bee** ([@Monay69](https://github.com/Monay69)) | Wallet registry · Vault · tests |
| **方瑜** ([@yufangyuri](https://github.com/yufangyuri)) | Web app |

---

## 🙏 Credits

The contract scaffold comes from the template of the ETHPanda × Reactive Network [Reactive Builder Camp](https://web3career.build/zh/programs/reactive-builder-camp). Cross-chain automation is powered by [Reactive Network](https://dev.reactive.network).
