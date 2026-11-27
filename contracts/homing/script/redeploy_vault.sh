#!/usr/bin/env bash
# 重新部署修好漏洞的金库（v2），并把 Reactive 合约指向它
#   登记簿和 Reactive 合约不变，只换金库
set -euo pipefail
cd "$(dirname "$0")/.."            # → contracts/homing
REPO_ROOT="$(cd ../.. && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/camp-template/starter/.env}"
set -a; source "$ENV_FILE"; set +a
source "$REPO_ROOT/.addresses"

LASNA_RPC="https://lasna-rpc.rnk.dev/"
SEPOLIA_RPC="${SEPOLIA_RPC_URL:-https://sepolia.gateway.tenderly.co}"
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4
CHANGE_DELAY=600
OLD_VAULT=$VAULT_ADDR

forge build >/dev/null && forge test >/dev/null && echo "44 个测试通过"

echo "[1/3] 部署新金库 → Sepolia"
OUT=$(forge create src/Vault.sol:Vault --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --value 0.02ether --broadcast \
  --constructor-args $PROXY "$REACTIVE_ADDR" $CHANGE_DELAY "$REGISTRY_ADDR")
VAULT=$(echo "$OUT" | grep "Deployed to" | awk '{print $3}')
echo "  新金库：$VAULT"

echo "[2/3] Reactive 合约改用新金库；演示阈值改成 2 分钟；定时检查开 60 次（约 2 小时）"
cast send "$REACTIVE_ADDR" "setVault(address)" "$VAULT" --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$REACTIVE_ADDR" "setIdleSeconds(uint256)" 120 --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$REACTIVE_ADDR" "setClock(bool,uint256)" false 0 --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" >/dev/null || true
cast send "$REACTIVE_ADDR" "setClock(bool,uint256)" true 60 --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" >/dev/null
echo "  vault() = $(cast call "$REACTIVE_ADDR" "vault()(address)" --rpc-url "$LASNA_RPC")"
echo "  clockOn() = $(cast call "$REACTIVE_ADDR" "clockOn()(bool)" --rpc-url "$LASNA_RPC")"
echo "  Lasna 上 Reactive 合约余额：$(cast balance "$REACTIVE_ADDR" --rpc-url "$LASNA_RPC" --ether) lREACT"

echo "[3/3] 更新地址记录"
sed -i "s/^VAULT_ADDR=.*/VAULT_ADDR=$VAULT/" "$REPO_ROOT/.addresses"
sed -i "s/$OLD_VAULT/$VAULT/g" "$REPO_ROOT/README.md" "$REPO_ROOT/README.zh-CN.md" "$REPO_ROOT/deployments.md" 2>/dev/null || true
echo "完成 ✅  新金库 $VAULT（旧金库 $OLD_VAULT 保留在链上，今天 13:34 的归集证据仍然有效）"
