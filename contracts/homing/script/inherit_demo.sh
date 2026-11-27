#!/usr/bin/env bash
# Homing 继承演示：一个用户（B）所有钱包都长期没动静 → 继承人领走他冷钱包里的币
#   用一个全新的「用户 B」来演示，不影响你主钱包的归集演示（金库里一个用户被继承后就不再归集）
#   演示用：继承期 10 分钟（真实使用会是几年）
#   三个一次性测试钱包的私钥只存在你电脑的 ~/.homing-*-key 里
set -euo pipefail
cd "$(dirname "$0")/../../.."      # → 仓库根目录
ENV_FILE="${ENV_FILE:-$HOME/camp-template/starter/.env}"
set -a; source "$ENV_FILE"; set +a
source .addresses

SEPOLIA_RPC="${SEPOLIA_RPC_URL:-https://sepolia.gateway.tenderly.co}"
INHERIT_PERIOD=600   # 10 分钟

s() {
  local i out
  for i in 1 2 3 4 5 6; do
    if out=$(cast send "$@" --rpc-url "$SEPOLIA_RPC" 2>&1); then sleep 3; return 0; fi
    case "$out" in
      *"nonce too low"*|*"replacement transaction"*|*"already known"*|*"timeout"*|*"503"*|*"429"*) sleep 8 ;;
      *) echo "$out" | tail -1 >&2; return 1 ;;
    esac
  done
  echo "  重试多次仍失败：$out" >&2; return 1
}
key() { local f="$HOME/.homing-$1-key"; [ -s "$f" ] || ( umask 077; echo "0x$(openssl rand -hex 32)" > "$f" ); cat "$f"; }
hmt() { cast from-wei "$(cast call "$TOKEN_ADDR" "balanceOf(address)(uint256)" "$1" --rpc-url "$SEPOLIA_RPC" | awk '{print $1}')"; }

BKEY=$(key owner-b);  B=$(cast wallet address --private-key "$BKEY")
CKEY=$(key cold-b);   COLD=$(cast wallet address --private-key "$CKEY")
HKEY=$(key heir-b);   HEIR=$(cast wallet address --private-key "$HKEY")
echo "用户 B（主钱包）：$B"
echo "B 的冷钱包：      $COLD"
echo "继承人：          $HEIR"

echo "[1/6] 给三个钱包转一点 ETH 当 gas"
s "$B"    --value 0.004ether --private-key "$PRIVATE_KEY"
s "$COLD" --value 0.003ether --private-key "$PRIVATE_KEY"
s "$HEIR" --value 0.003ether --private-key "$PRIVATE_KEY"

echo "[2/6] 两个钱包在登记簿登记（钱包本人签名；Reactive 开始盯它们）"
s "$REGISTRY_ADDR" "register(address,uint8)" "$B" 0 --private-key "$BKEY"    2>/dev/null || echo "  已登记过，跳过"
s "$REGISTRY_ADDR" "register(address,uint8)" "$B" 1 --private-key "$CKEY"    2>/dev/null || echo "  已登记过，跳过"

echo "[3/6] B 在金库里设规则：继承人 = $HEIR，继承期 10 分钟，冷钱包算在继承里"
s "$VAULT_ADDR" "configure(address,address,uint256,uint256,uint256,bool)" "$B" "$HEIR" 240 60 $INHERIT_PERIOD true --private-key "$BKEY" 2>/dev/null || echo "  已经设过规则，跳过"
s "$VAULT_ADDR" "linkWallet(address)" "$B" --private-key "$BKEY"
s "$VAULT_ADDR" "linkWallet(address)" "$COLD" --private-key "$BKEY"
s "$VAULT_ADDR" "setTokenAllowed(address,bool)" "$TOKEN_ADDR" true --private-key "$BKEY"

echo "[4/6] B 的主钱包放 20 HMT、冷钱包放 50 HMT，都授权给金库"
s "$TOKEN_ADDR" "mint(address,uint256)" "$B" 20000000000000000000 --private-key "$PRIVATE_KEY"
s "$TOKEN_ADDR" "mint(address,uint256)" "$COLD" 50000000000000000000 --private-key "$PRIVATE_KEY"
s "$TOKEN_ADDR" "approve(address,uint256)" "$VAULT_ADDR" "$(cast max-uint)" --private-key "$BKEY"
s "$TOKEN_ADDR" "approve(address,uint256)" "$VAULT_ADDR" "$(cast max-uint)" --private-key "$CKEY"
echo "  B 主钱包 HMT：$(hmt "$B")   冷钱包 HMT：$(hmt "$COLD")   继承人 HMT：$(hmt "$HEIR")"

echo "[5/6] 继承人现在就来领 → 应该被拒（B 的钱包还在期限内）"
if cast call "$VAULT_ADDR" "claim(address)" "$B" --from "$HEIR" --rpc-url "$SEPOLIA_RPC" >/dev/null 2>&1; then
  echo "  ⚠️ 没被拒，检查一下设置"
else
  echo "  ✅ 被拒：StillActive（还没到期，谁都领不走）"
fi

echo
echo "[6/6] B 的所有钱包都不再动。等 10 分钟后继承人来领……"
for i in $(seq 1 40); do
  sleep 30
  if cast call "$VAULT_ADDR" "claim(address)" "$B" --from "$HEIR" --rpc-url "$SEPOLIA_RPC" >/dev/null 2>&1; then
    echo "  $(date +%H:%M:%S)  到期了，继承人发起领取"
    s "$VAULT_ADDR" "claim(address)" "$B" --private-key "$HKEY"
    echo
    echo "🏠 交到家人手里了！继承人 HMT：$(hmt "$HEIR")（应为 70）   B 主钱包：$(hmt "$B")   冷钱包：$(hmt "$COLD")"
    break
  fi
  echo "  $(date +%H:%M:%S)  还没到期"
done

echo
echo "链上证据："
echo "  继承人收到的币：https://sepolia.etherscan.io/address/$HEIR#tokentxns"
echo "  冷钱包：        https://sepolia.etherscan.io/address/$COLD#tokentxns"
echo "  金库：          https://sepolia.etherscan.io/address/$VAULT_ADDR"
