#!/usr/bin/env bash
set -euo pipefail

# integration test with lua node
./lua_poc/attached_entrypoint.lua &
sleep 20

exec env RUST_LOG="info" ./compute-rs/target/release/dave-compute
