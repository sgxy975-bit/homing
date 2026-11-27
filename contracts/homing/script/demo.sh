#!/usr/bin/env bash
# Homing 链上演示：一个钱包被遗忘 → 5 分钟后被自动归集回主钱包
#   主钱包 = 你 .env 里的钱包（日常钱包，tag 0）
#   被遗忘的钱包 = 脚本新建的一次性测试钱包（可归集，tag 2），私钥只存在 ~/.homing-demo-key
set -euo pipefail
cd "$(dirname "$0")/../../.."      # → 仓库根目录
ENV_FILE="${ENV_FILE:-$HOME/camp-template/starter/.env}"
set -a; source "$ENV_FILE"; set +a
source .addresses   # 放在 .env 后面：.env 里旧作业的 REACTIVE_ADDR 等变量不会覆盖新地址

SEPOLIA_RPC="${SEPOLIA_RPC_URL:-https://sepolia.gateway.tenderly.co}"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
# 发交易：公共节点偶尔会报 nonce too low（多台服务器没同步），等几秒重试
s() {
  local i
  for i in 1 2 3 4 5 6; do
    if out=$(cast send "$@" --rpc-url "$SEPOLIA_RPC" 2>&1); then sleep 3; return 0; fi
    case "$out" in
      *"nonce too low"*|*"replacement transaction"*|*"already known"*|*"timeout"*|*"503"*|*"429"*) sleep 8 ;;
      *) echo "$out" | tail -1 >&2; return 1 ;;
    esac
  done
  echo "  重试多次仍失败：$out" >&2; return 1
}

# 一次性「被遗忘钱包」（只在测试网用）
KEYFILE="$HOME/.homing-demo-key"
if [ ! -s "$KEYFILE" ]; then
  ( umask 077; echo "0x$(openssl rand -hex 32)" > "$KEYFILE" )
fi
FKEY=$(cat "$KEYFILE")
FORGOTTEN=$(cast wallet address --private-key "$FKEY")
echo "主钱包：      $ME"
echo "被遗忘的钱包：$FORGOTTEN"

echo "[1/6] 给被遗忘的钱包转 0.005 ETH 当 gas"
s "$FORGOTTEN" --value 0.005ether --private-key "$PRIVATE_KEY"

echo "[2/6] 在金库里配置规则：等待 240 秒 + 宽限 60 秒（演示），继承人先填自己"
s "$VAULT_ADDR" "configure(address,address,uint256,uint256,uint256,bool)" "$ME" "$ME" 240 60 31536000 false --private-key "$PRIVATE_KEY"
s "$VAULT_ADDR" "linkWallet(address,uint8)" "$ME" 0 --private-key "$PRIVATE_KEY"
s "$VAULT_ADDR" "linkWallet(address,uint8)" "$FORGOTTEN" 2 --private-key "$PRIVATE_KEY"
s "$VAULT_ADDR" "setTokenAllowed(address,bool)" "$TOKEN_ADDR" true --private-key "$PRIVATE_KEY"

echo "[3/6] 两个钱包各自在登记簿登记（→ WalletAdded → Reactive 开始盯它们）"
s "$REGISTRY_ADDR" "register(address,uint8)" "$ME" 0 --private-key "$PRIVATE_KEY" 2>/dev/null || echo "  主钱包之前登记过，跳过"
s "$REGISTRY_ADDR" "register(address,uint8)" "$ME" 2 --private-key "$FKEY" 2>/dev/null || echo "  被遗忘的钱包之前登记过，跳过"

echo "[4/6] 被遗忘的钱包里放 100 HMT，并授权给金库"
s "$TOKEN_ADDR" "mint(address,uint256)" "$FORGOTTEN" 100000000000000000000 --private-key "$PRIVATE_KEY"
s "$TOKEN_ADDR" "approve(address,uint256)" "$VAULT_ADDR" "$(cast max-uint)" --private-key "$FKEY"

echo "[5/6] 主钱包转一笔 HMT（证明「人还在」→ 应触发 onActivity 回调）"
s "$TOKEN_ADDR" "mint(address,uint256)" "$ME" 10000000000000000000 --private-key "$PRIVATE_KEY"
sleep 20   # 等 Reactive 先处理完 WalletAdded（订阅生效后才看得到转账）
s "$TOKEN_ADDR" "transfer(address,uint256)" "$FORGOTTEN" 1000000000000000000 --private-key "$PRIVATE_KEY"

echo "  Reactive 正在盯的钱包数：$(cast call "$REACTIVE_ADDR" "walletCount()(uint256)" --rpc-url "$LASNA_RPC")"
echo
echo "[6/6] 现在什么都不用做，等它自己归集（最多约 10 分钟）……"
START_BAL=$(cast call "$TOKEN_ADDR" "balanceOf(address)(uint256)" "$FORGOTTEN" --rpc-url "$SEPOLIA_RPC" | awk '{print $1}')
for i in $(seq 1 40); do
  sleep 20
  BAL=$(cast call "$TOKEN_ADDR" "balanceOf(address)(uint256)" "$FORGOTTEN" --rpc-url "$SEPOLIA_RPC" | awk '{print $1}')
  echo "  $(date +%H:%M:%S)  被遗忘钱包的 HMT 余额：$(cast from-wei "$BAL")"
  if [ "$BAL" = "0" ]; then
    echo
    echo "🏠 回家了！被遗忘钱包的 HMT 已经被归集到主钱包。"
    break
  fi
done

echo
echo "链上证据（交给黑客松用）："
echo "  Reactive 合约（看 react 交易）：https://lasna.reactscan.net/address/$REACTIVE_ADDR"
echo "  金库（看 onActivity / onSweep 回调交易）：https://sepolia.etherscan.io/address/$VAULT_ADDR#internaltx"
echo "  被遗忘的钱包：https://sepolia.etherscan.io/address/$FORGOTTEN#tokentxns"
