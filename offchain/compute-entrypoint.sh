#!/bin/sh

/usr/bin/jsonrpc-remote-cartesi-machine --server-address=127.0.0.1:5002 >/dev/null 2>&1 &
# if integration test with lua node
cd /root/permissionless-arbitration && ./lua_node/single_dishonest_entrypoint.lua &
cd - && sleep 30
# end of integration test
RUST_LOG="info" target/release/dave-compute
