#!/usr/bin/env bash
set -euo pipefail

# Paths
RETH_DIR="$HOME/Library/Application Support/reth"
BUILDER_PLAYGROUND_DIR="$HOME/projects/prop-amm/builder-playground"
UNICHAIN_BUILDER_DIR="$HOME/projects/prop-amm/unichain-builder"
GLOBAL_STORAGE_DIR="$HOME/projects/prop-amm/global-storage"
PROP_AMM_DIR="$HOME/projects/prop-amm/prop-amm"
TOKEN_DEPLOYER_DIR="$HOME/projects/prop-amm/token-deployer"

run_in_new_terminal() {
  local title="$1"
  local dir="$2"
  shift 2
  # Preserve argument quoting so flags like --sig "run(string,string)" survive
  local cmd
  cmd=$(printf "%q " "$@")

  osascript <<EOF
tell application "Terminal"
  activate
  do script "printf '\\\033]0;$title\\\007'; cd \"$dir\" && $cmd"
end tell
EOF
}

echo "1) Removing reth folder at: $RETH_DIR"
if [ -d "$RETH_DIR" ]; then
  rm -rf "$RETH_DIR"
  echo "   Deleted."
else
  echo "   Skipped (not found)."
fi

echo "2) Running go run cook opstack (builder-playground)..."
run_in_new_terminal "builder-playground" "$BUILDER_PLAYGROUND_DIR" \
  go run main.go cook opstack \
    --block-time 1 \
    --flashblocks \
    --external-builder http://host.docker.internal:4444 \
    --with-prometheus \
    --flashblocks-builder ws://host.docker.internal:1111 \
    --base-overlay \
    --enable-websocket-proxy

sleep 20

echo "3) Starting unichain-builder node..."
run_in_new_terminal "unichain-builder" "$UNICHAIN_BUILDER_DIR" \
  ./target/release/unichain-builder node \
    --chain "$HOME/.playground/devnet/l2-genesis.json" \
    --http \
    --http.port 2222 \
    --authrpc.port 4444 \
    --authrpc.jwtsecret "$HOME/.playground/devnet/jwtsecret" \
    --port 30333 \
    --disable-discovery \
    --metrics 0.0.0.0:5555 \
    --rollup.builder-secret-key 59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
    --builder.global-storage-address 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \ -- When running on my computer, this is what the global storage address results to.
    --trusted-peers enode://79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8@127.0.0.1:30304 \
    --authrpc.addr 0.0.0.0 \
    --flashblocks 0.0.0.0:1111 \
    --flashblocks.interval 200m

sleep 15

echo "4) Running forge create (global-storage)..."
run_in_new_terminal "global-storage" "$GLOBAL_STORAGE_DIR" \
  forge create ./src/GlobalStorage.sol:GlobalStorage \
    --rpc-url http://localhost:8547 \
    --private-key $PRIVATE_KEY \
    --broadcast

sleep 5

echo "5) Deploying USDC and WETH Smart Contract..."
run_in_new_terminal "token-deployer" "$TOKEN_DEPLOYER_DIR" \
  forge script script/DeployToken.s.sol:DeployToken \
    --rpc-url http://localhost:8547 \
    --private-key $PRIVATE_KEY \
    --broadcast 

sleep 10

echo "6) Deploying Prop AMM Smart Contract..."
run_in_new_terminal "prop-amm" "$PROP_AMM_DIR" \
  forge script script/PropAMM.s.sol:PropAMMScript \
    --rpc-url http://localhost:8547 \
    --private-key $PRIVATE_KEY \
    --broadcast 


echo "All tasks completed."