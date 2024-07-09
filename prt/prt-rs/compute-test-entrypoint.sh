#!/usr/bin/env bash
set -euo pipefail

# integration test with lua node
./lua_poc/attached_entrypoint.lua &
sleep 20

exec env RUST_LOG="info" ./prt-rs/target/release/cartesi-prt-compute
