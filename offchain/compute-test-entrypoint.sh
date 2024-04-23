#!/usr/bin/env bash
set -euo pipefail

# integration test with lua node
cd /root/permissionless-refereed-tournaments && ./lua_node/attached_entrypoint.lua &
cd -
sleep 60

exec RUST_LOG="info" target/release/dave-compute
