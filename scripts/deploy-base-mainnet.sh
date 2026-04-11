#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RPC_URL="${BASE_RPC_URL:-${RPC_URL:-}}"

if [[ -z "$RPC_URL" ]]; then
  echo "Set BASE_RPC_URL or RPC_URL before running this script." >&2
  exit 1
fi

if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "Set DEPLOYER_PRIVATE_KEY before running this script." >&2
  exit 1
fi

INITIAL_FEE_BPS="${INITIAL_FEE_BPS:-0}"
if [[ "$INITIAL_FEE_BPS" != "0" && -z "${INITIAL_FEE_RECIPIENT:-}" ]]; then
  echo "Set INITIAL_FEE_RECIPIENT when INITIAL_FEE_BPS is non-zero." >&2
  exit 1
fi

FORGE_CMD=(
  forge script script/DeployBaseMainnet.s.sol:DeployBaseMainnet
  --rpc-url "$RPC_URL"
  --broadcast
)

if [[ "${VERIFY:-0}" == "1" ]]; then
  if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
    echo "Set ETHERSCAN_API_KEY when VERIFY=1." >&2
    exit 1
  fi
  FORGE_CMD+=(--verify)
fi

echo "Deploying MoltTrade contracts to Base mainnet (chainId 8453)"
echo "RPC_URL=$RPC_URL"

if [[ -n "${SETTLEMENT_OWNER:-}" ]]; then
  echo "SETTLEMENT_OWNER=$SETTLEMENT_OWNER"
fi

"${FORGE_CMD[@]}" "$@"
