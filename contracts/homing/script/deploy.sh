#!/usr/bin/env bash
# Homing 一键部署（在你自己电脑的 WSL 里运行）
#   1. HomingReactive  → Reactive Lasna
#   2. Vault（bee）     → Ethereum Sepolia（构造函数需要第 1 步的地址）
#   3. HomeToken (HMT) → Ethereum Sepolia（演示用测试币）
#   4. setVault + 打开定时检查
#   5. 地址写进 deployments.md 和 README，推送到 GitHub
# 私钥只从本机 .env 读取，脚本不会打印它。
set -euo pipefail

cd "$(dirname "$0")/.."            # → contracts/homing
REPO_ROOT="$(cd ../.. && pwd)"

ENV_FILE="${ENV_FILE:-$HOME/camp-template/starter/.env}"
[ -f "$ENV_FILE" ] || { echo "找不到 $ENV_FILE（里面要有 PRIVATE_KEY）"; exit 1; }
set -a; source "$ENV_FILE"; set +a
[ -n "${PRIVATE_KEY:-}" ] || { echo ".env 里没有 PRIVATE_KEY"; exit 1; }

# 依赖库：直接复用训练营模板里装好的
if [ ! -d lib/reactive-lib-omni ] || [ ! -d lib/forge-std ]; then
  mkdir -p lib
  cp -r "$HOME/camp-template/starter/lib/forge-std" "$HOME/camp-template/starter/lib/reactive-lib-omni" lib/
fi

LASNA_RPC="https://lasna-rpc.rnk.dev/"
SEPOLIA_RPC="${SEPOLIA_RPC_URL:-https://sepolia.gateway.tenderly.co}"
SEPOLIA=11155111
BASE_SEPOLIA=84532
REGISTRY=0xEaFFd84aFEF8EE1fCcA7e066d166BD5Dd7B6B7d6        # bee 已部署
SEPOLIA_CALLBACK_PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4

IDLE_SECONDS=300        # Reactive 认为「被遗忘」的阈值：演示 5 分钟
ACTIVITY_GAP=60         # onActivity 节流
CHANGE_DELAY=600        # 金库：改归集地址/继承人要等 10 分钟生效（演示）
CLOCK_TICKS=30          # 定时检查跑 30 次（约 1 小时）后自动停，防止费用失控
REACTIVE_FUNDING=2ether # lREACT，付 Lasna 上的执行费
VAULT_FUNDING=0.02ether # Sepolia ETH，付回调费

ME=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "部署钱包：$ME"
echo "Lasna 余额：$(cast balance "$ME" --rpc-url "$LASNA_RPC" --ether) lREACT"
echo "Sepolia 余额：$(cast balance "$ME" --rpc-url "$SEPOLIA_RPC" --ether) ETH"
echo

forge build >/dev/null
echo "编译通过，开始部署……"

deploy() { # deploy <rpc> <value> <contract> [constructor args...]
  local rpc=$1 value=$2 contract=$3; shift 3
  local out
  if [ "$#" -gt 0 ]; then
    out=$(forge create "$contract" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --value "$value" --broadcast --constructor-args "$@")
  else
    out=$(forge create "$contract" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --value "$value" --broadcast)
  fi
  echo "$out" | grep -E "Deployed to|Transaction hash" >&2
  echo "$out" | grep "Deployed to" | awk '{print $3}'
}

echo "[1/5] HomingReactive → Lasna"
REACTIVE=$(deploy "$LASNA_RPC" "$REACTIVE_FUNDING" src/HomingReactive.sol:HomingReactive \
  $SEPOLIA $REGISTRY "[$SEPOLIA,$BASE_SEPOLIA]" $IDLE_SECONDS $ACTIVITY_GAP)

echo "[2/5] Vault → Sepolia"
VAULT=$(deploy "$SEPOLIA_RPC" "$VAULT_FUNDING" src/Vault.sol:Vault \
  $SEPOLIA_CALLBACK_PROXY "$REACTIVE" $CHANGE_DELAY)

echo "[3/5] HomeToken → Sepolia"
TOKEN=$(deploy "$SEPOLIA_RPC" 0 src/HomeToken.sol:HomeToken)

echo "[4/5] setVault + 打开定时检查（Lasna）"
cast send "$REACTIVE" "setVault(address)" "$VAULT" --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$REACTIVE" "setClock(bool,uint256)" true $CLOCK_TICKS --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" >/dev/null
echo "  vault() = $(cast call "$REACTIVE" "vault()(address)" --rpc-url "$LASNA_RPC")"
echo "  clockOn() = $(cast call "$REACTIVE" "clockOn()(bool)" --rpc-url "$LASNA_RPC")"

cat > "$REPO_ROOT/deployments.md" <<EOF
# Deployments (testnet)

Deployed $(date -u +"%Y-%m-%d %H:%M UTC") by \`$ME\`.

| Contract | Chain | Address |
|---|---|---|
| WalletRegistry (bee) | Ethereum Sepolia | [\`$REGISTRY\`](https://sepolia.etherscan.io/address/$REGISTRY) |
| HomingReactive | Reactive Lasna | [\`$REACTIVE\`](https://lasna.reactscan.net/address/$REACTIVE) |
| Vault | Ethereum Sepolia | [\`$VAULT\`](https://sepolia.etherscan.io/address/$VAULT) |
| HomeToken (HMT, demo) | Ethereum Sepolia | [\`$TOKEN\`](https://sepolia.etherscan.io/address/$TOKEN) |

Settings: idleSeconds=$IDLE_SECONDS, activityGap=$ACTIVITY_GAP, vault CHANGE_DELAY=$CHANGE_DELAY, clock ticks=$CLOCK_TICKS (Cron100 ≈ 2 min).
Watched chains: Ethereum Sepolia ($SEPOLIA), Base Sepolia ($BASE_SEPOLIA).
EOF

# README 里的 TBD 换成真实地址
sed -i "s#| HomingReactive | Lasna | TBD |#| HomingReactive | Lasna | \`$REACTIVE\` |#; s#| Vault | Sepolia | TBD |#| Vault | Sepolia | \`$VAULT\` |\n| HomeToken (HMT, demo) | Sepolia | \`$TOKEN\` |#" "$REPO_ROOT/README.md"

# 也写一份给自己（WSL 里后续命令用）
{
  echo "REACTIVE_ADDR=$REACTIVE"
  echo "VAULT_ADDR=$VAULT"
  echo "TOKEN_ADDR=$TOKEN"
  echo "REGISTRY_ADDR=$REGISTRY"
} > "$REPO_ROOT/.addresses"

echo "[5/5] 推送到 GitHub"
cd "$REPO_ROOT"
git add -A
git commit -m "Deploy testnet: HomingReactive (Lasna), Vault + HomeToken (Sepolia)" >/dev/null
git push

echo
echo "完成 ✅"
cat deployments.md
