# Deployments (testnet)

Deployer: `0xd1a3d69F33668A5fF1D825Bc4A07Bc2Cdd920A99`

| Contract | Chain | Address | Notes |
|---|---|---|---|
| WalletRegistry (bee) | Ethereum Sepolia | [`0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6`](https://sepolia.etherscan.io/address/0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6) | |
| HomingReactive | Reactive Lasna | [`0x80c1346fcc786077BBef753d560594803fBc8fa7`](https://lasna.reactscan.net/address/0x80c1346fcc786077BBef753d560594803fBc8fa7) | deployed 2026-11-27 13:16 UTC |
| **Vault v2** (current) | Ethereum Sepolia | [`0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4`](https://sepolia.etherscan.io/address/0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4) | security fixes: registry-checked ownership, configure once, primary included in inheritance |
| Vault v1 (retired) | Ethereum Sepolia | [`0x8F40597510bdC7f89832189cC3e233ff9942A8B9`](https://sepolia.etherscan.io/address/0x8F40597510bdC7f89832189cC3e233ff9942A8B9) | first sweep 13:34 UTC, kept as evidence |
| HomeToken (HMT, demo) | Ethereum Sepolia | [`0x0db140Bb118A264C0E221d75f49aFb1db9C28660`](https://sepolia.etherscan.io/address/0x0db140Bb118A264C0E221d75f49aFb1db9C28660) | |

## Current settings

| Setting | Value |
|---|---|
| Reactive `idleSeconds` | 120 (demo) |
| Reactive `activityGap` | 60 s |
| Watched chains | Ethereum Sepolia (11155111), Base Sepolia (84532) |
| Clock | Cron100 (~2 min), turned on per demo with a tick limit |
| Vault `CHANGE_DELAY` | 600 s (demo) |
| Demo owner's vault rules | wait 90 s + grace 30 s; inheritance 10 min (inheritance demo user) |

## Key transactions

| What | Transaction |
|---|---|
| `onActivity` callback (vault v1) | [`0x5df95bf1…bb0a`](https://sepolia.etherscan.io/tx/0x5df95bf1bcae5d900885b926a79428f6177fa2a7d7c7043467a27efb4cc2bb0a) |
| First sweep, 101 HMT (vault v1) | [`0x4178d159…9b46`](https://sepolia.etherscan.io/tx/0x4178d15939d1ab3ef67ea8fcf6560d35ac930ffdbcfa6d27ad29584b20669b46) |
| Sweep, 100 HMT (vault v2) | [`0xc7c86e6d…f81c`](https://sepolia.etherscan.io/tx/0xc7c86e6dd0e4ff604e7d2465db54c069353124bad027e474728a04a45f61f81c) |
| Inheritance `claim()`, 70 HMT (vault v2) | [`0x177fc329…32af`](https://sepolia.etherscan.io/tx/0x177fc329a9f3eaa53092036de5c5f8182d16c9e9378a73303358ca71e45132af) |
