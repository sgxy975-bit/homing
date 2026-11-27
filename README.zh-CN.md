<p align="center"><img src="assets/homing-logo-cream.png" alt="Homing" width="420"></p>

<p align="center"><a href="README.md">English</a> · <b>中文</b></p>

# Homing

**像信鸽一样，被忘掉的钱总能自己找回家。**

> **Homing** 帮你看着所有链上的所有钱包。哪个钱包被你忘了，先提醒你；如果你一直没响应，就把里面的币转回你常用的钱包。要是所有钱包都很久没动静，就交给你指定的继承人。规则写在链上，由 Reactive Network 自动执行。

[![Reactive Network](https://img.shields.io/badge/Reactive_Network-Lasna-F05C00?style=for-the-badge)](https://dev.reactive.network)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.29-363636?style=for-the-badge&logo=solidity)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Foundry-44_tests_passing-1C1C1E?style=for-the-badge)](https://getfoundry.sh)
[![Testnet](https://img.shields.io/badge/Sepolia_%2B_Base_Sepolia-testnet-627EEA?style=for-the-badge&logo=ethereum)](https://sepolia.etherscan.io/address/0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4)

Reactive Omni Buildathon · 赛道 2（Set It and Forget It）

在线演示：[打开网页](https://htmlpreview.github.io/?https://github.com/sgxy975-bit/homing/blob/main/frontend/index.html) · 链上证据见下文

---

## 🎯 痛点

- **目标用户：** 小林，玩币三年，手上有七八个钱包：一个日常用，不少用来领空投，还有为测试项目特意建的。
- **问题：** 旧钱包里的零钱就这么忘了。万一人出了意外，家里人根本不知道这些钱包存在，钱就永远没了。
- **现有工具都只解决了一部分：**
  - **Casa、Vault12**：用户永久未响应，家里人拿不到钱。用多签或信任的守护人保管密钥碎片，出事后家人能恢复钱包。
  - **Ledger Recover**：怕助记词丢了。把加密的助记词拆成几份，交给几家公司保管，丢了能找回。
  - **Sarcophagus**：用户到期没报平安，就把事先加密好的文件（比如助记词）交给指定的人。
  - **BitGo、Ripple Custody**：给交易所和企业用，解决成千上万个充值地址里的钱要定期收拢的问题，但钱得交给它们托管。

  它们要么只管人走以后，要么要你交出密钥或资产。还没有一个工具，能在你还在的时候就帮你归集钱包里的币。
- **Homing 的做法：**
  1. **登记一次。** 每个钱包自己签名登记，并打上标签：主钱包、冷钱包、可归集。
  2. **一直盯着。** Reactive 合约跟着每个钱包在各条链上的转账，有动静就说明人还在。
  3. **忘了就领回家。** 某个钱包太久没动，提醒 → 宽限期 → 币转回主钱包。
  4. **人不在了就交给家人。** 所有钱包都很久没动静，继承人可以来领。

---

## 📱 怎么运作

钱包登记一次就行。之后 Homing 一步步来，任何一个钱包有动静，计时就重新开始。

| 情况 | Homing 做什么 |
| --- | --- |
| 所有钱包都在用 | 什么都不做 |
| 某个钱包很久没动（比如 6 个月） | 提醒 → 宽限期 → 把币转回主钱包 |
| **所有**钱包都很久没动（比如 3 年） | 继承人可以领取（冷钱包要你事先同意才算在内） |

| 标签 | 是什么 |
| --- | --- |
| **主钱包** | 日常用的。它一动，就说明你还在；归集的币也转到这里。 |
| **冷钱包** | 永远不自动归集，只在继承时参与，而且要你事先同意。 |
| **可归集** | 提醒、宽限期过后，币会被领回家。 |

---

## ⛓️ 测试网上已经跑通

2026-11-27，两半都用真实交易跑通了：一个被忘掉的钱包自己回了家；一个所有钱包都没了动静的用户，钱被继承人领走了。

| 步骤 | 交易 |
| --- | --- |
| 主钱包转了一笔币 → Reactive 看到 → **`onActivity`** 回调告诉金库“人还在” | [`0x5df95bf1…bb0a`](https://sepolia.etherscan.io/tx/0x5df95bf1bcae5d900885b926a79428f6177fa2a7d7c7043467a27efb4cc2bb0a)（金库 v1） |
| 被忘掉的钱包闲置 2 分钟 → Reactive 请求归集 → **`onSweep`** 回调 → 100 HMT 回家 | [`0xc7c86e6d…f81c`](https://sepolia.etherscan.io/tx/0xc7c86e6dd0e4ff604e7d2465db54c069353124bad027e474728a04a45f61f81c) |
| 继承人提前来领 → 被拒（`StillActive`）；10 分钟没动静后 → **`claim()`** → 70 HMT（主钱包 20 + 冷钱包 50）到继承人手里 | [`0x177fc329…32af`](https://sepolia.etherscan.io/tx/0x177fc329a9f3eaa53092036de5c5f8182d16c9e9378a73303358ca71e45132af) |
| Reactive 合约每一次 `react()` | [Reactscan](https://lasna.reactscan.net/address/0x80c1346fcc786077BBef753d560594803fBc8fa7) |

**已在测试网上跑着：** 钱包登记簿、跨链活动追踪（动态订阅）、过半预警、宽限期、带金库复核的自动归集、继承领取 `claim()`、延迟修改设置，以及 44 个测试（含失败路径、安全回归测试和端到端测试）。

---

## ⚡ 为什么用 Reactive

- **天生跨链。** 钱包散在好几条链上，一个 Reactive 合约就能全盯着（现在是 Ethereum Sepolia 和 Base Sepolia），再把消息报给金库。没有 Reactive，就得自己养一台 24 小时开着的服务器。
- **不用自己维护任何东西。** 钱包一动，事件自己推过来；闲置检查靠一个有次数上限的定时器。没有机器人，没有后端。
- **规则公开。** 每一次提醒和归集都按链上的规则来，谁都能查。

---

## 🛠️ 技术栈与架构

```
 Ethereum Sepolia / Base Sepolia        Reactive Lasna                 Ethereum Sepolia
 WalletRegistry ── WalletAdded ───▶  HomingReactive  ── 订阅 ─────────▶ 这个钱包的转账
 钱包转出代币 ────────────────────▶     react()      ── onActivity ──▶ 金库：“人还在”
 定时器（Cron，约 2 分钟）────────▶     react()      ── onSweep ─────▶ 金库：复核 → 归集
```

| 模块 | 在哪 | 技术 | 干什么 |
| --- | --- | --- | --- |
| **WalletRegistry 登记簿** | Sepolia | Solidity 0.8.29 | 钱包自己来登记，写明主人和标签，发出 `WalletAdded` |
| **HomingReactive** | Reactive Lasna | Solidity + Reactive Omni | 收到 `WalletAdded` 就去订阅这个钱包在各条链上的转账（动态订阅）；记最后活跃时间，过半时预警，到期请金库归集 |
| **Vault 金库** | Sepolia | Solidity 0.8.29 | 只拿代币授权，不拿钱。动钱之前用自己的数据再核对一遍期限。继承领取 `claim()` 和延迟修改设置也在这里 |
| **网页** | 浏览器 | HTML / CSS / JS | 连钱包、一页看全部、登记和授权、看倒计时 |
| **测试和部署** | 本地 | Foundry | 44 个测试，一键部署和演示脚本 |

三方共用的接口：[`contracts/homing/src/IHoming.sol`](contracts/homing/src/IHoming.sol)。

---

## 🔒 安全

- **不托管。** 币一直在你自己的钱包里，金库只用你给的授权，随时能撤销。
- **两道检查。** Reactive 决定“什么时候问”，金库决定“做不做”。时间其实还没到，金库就直接跳过，不 revert，也不动钱。
- **只有我们的 Reactive 合约能触发归集**（Callback Proxy + 发送方校验）。
- **别人挂不走你的钱包。** 钱包归属以登记簿为准：只有钱包本人签名声明“我属于你”，你才能把它挂到自己名下。在登记簿里移除或改了标签的钱包，金库马上就不再归集，也不会被继承人领走。
- **改设置要等。** 改归集地址或继承人，要过一段等待期才生效，没人能在最后一刻偷偷换掉。
- **费用不会失控。** 演示版整个合约最多盯 20 个钱包；定时器跑够次数自己停；活动上报有节流；归集重试有间隔。

---

## 🆚 和市场上的产品有什么不同

| 产品 | 类型 | Homing 的不同 |
| --- | --- | --- |
| Ripple Custody、BitGo（[Ripple](https://docs.ripple.com/products/wallet/changelogs/asset-sweeping-now-available)） | 交易所用的定时归集 | 给个人用；按钱包被忘了多久来触发；不托管 |
| Casa、Ledger Recover、Vault12（[概述](https://chain.com/blog/who-inherits-your-wallet)） | 靠密钥继承 | 只交出钱，不交出密钥；人还在时也有用 |
| Sarcophagus（[对比](https://www.spark.money/tools/crypto-estate-planning-comparison)） | 到期后公开加密保存的秘密（比如助记词） | 按规则转钱，而不是公开秘密 |

---

## 🚀 快速开始

```bash
cd contracts/homing
forge install foundry-rs/forge-std Reactive-Network/reactive-lib-omni --no-git
forge test                       # 44 个测试
bash script/deploy.sh            # 一键部署（.env 里要有 PRIVATE_KEY，还要一点 lREACT 和 Sepolia ETH）
bash script/demo.sh              # 归集演示：大约 2 分钟后看钱包回家
bash script/inherit_demo.sh      # 继承演示：大约 10 分钟后继承人领取
```

网页不用安装：直接在浏览器里打开 `frontend/index.html`。

---

## 📁 项目结构

```
contracts/homing/src/HomingReactive.sol   Reactive 合约（Lasna）
contracts/homing/src/WalletRegistry.sol   钱包登记簿（Sepolia）
contracts/homing/src/Vault.sol            金库（Sepolia）
contracts/homing/src/IHoming.sol          三方共用接口
contracts/homing/src/HomeToken.sol        演示用测试币 HMT
contracts/homing/test/                    44 个测试
contracts/homing/script/                  部署和演示脚本
frontend/index.html                       网页（单文件）
assets/                                   Logo
deployments.md                            部署地址记录
```

---

## 📍 部署地址（测试网）

| 合约 | 链 | 地址 |
| --- | --- | --- |
| WalletRegistry | Ethereum Sepolia | [`0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6`](https://sepolia.etherscan.io/address/0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6) |
| HomingReactive | Reactive Lasna | [`0x80c1346fcc786077BBef753d560594803fBc8fa7`](https://lasna.reactscan.net/address/0x80c1346fcc786077BBef753d560594803fBc8fa7) |
| Vault（v2，已修安全问题） | Ethereum Sepolia | [`0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4`](https://sepolia.etherscan.io/address/0xCCDb1aBC0B06e40Ec0162616491c9Ce74488f6d4) |
| HomeToken（HMT，演示币） | Ethereum Sepolia | [`0x0db140Bb118A264C0E221d75f49aFb1db9C28660`](https://sepolia.etherscan.io/address/0x0db140Bb118A264C0E221d75f49aFb1db9C28660) |

演示设置：2 分钟没动算被忘（金库：等 90 秒 + 宽限 30 秒），10 分钟没动静可继承，定时器跑 60 次（约 2 小时）。真实使用时会是几个月、几年。金库 v1（`0x8F40…A8B9`）仍留在链上，里面有 13:34 的第一次归集。

---

## 🧭 路线图

下面这些已经规划，**还没做**：

- 🛡️ **守护模式**：所有钱包都没动静时，一部分冻结，一部分放进稳健理财并设止损
- 🤖 **AI 配置助手**：建议冻结和理财的比例，你看过、签了名才上链
- 📨 **邮件或 Telegram 提醒**（链下）
- ⛽ **两边费用自动续费**（lREACT 和 ETH）
- 👛 **在 app 里直接建钱包并自动登记**
- ✍️ **一次登记好所有钱包**：每个钱包只签一个名（离线签名，不花 gas），主钱包把所有签名打包成一笔交易提交；代币授权也改成签名（Permit / Permit2），不用每种代币发一笔交易

**用户使用模式设想：**

| 套餐 | 包含 |
| --- | --- |
| Free | 汇总查看和提醒，不用 Reactive |
| Pro | 自动归集以及自动理财 |
| Pro Max | 守护模式和继承 |

---

## ⚠️ 局限

- 钱包得自己登记，没登记的看不到。
- 只有代币转账算“有动静”，直接转 ETH 不会发事件。
- 每种代币都要单独授权一次。
- 只支持 Reactive 接入的 EVM 链（不支持比特币、Solana、交易所账户）。这个版本只在 Sepolia 上归集。
- 只在测试网，没审计，也不是法律意义上的遗嘱。

---

## 👥 团队

| 成员 | 分工 |
| --- | --- |
| **Yilin**（[@sgxy975-bit](https://github.com/sgxy975-bit)） | 项目负责人 · Reactive 合约 · 联调和部署 |
| **bee**（[@Monay69](https://github.com/Monay69)） | 钱包登记簿 · 金库 · 测试 |
| **方瑜**（[@yufangyuri](https://github.com/yufangyuri)） | 网页前端 |

---

## 🙏 致谢

合约框架来自 ETHPanda × Reactive Network 的 [Reactive Builder Camp](https://web3career.build/zh/programs/reactive-builder-camp) 模板仓库，跨链自动化由 [Reactive Network](https://dev.reactive.network) 提供。
