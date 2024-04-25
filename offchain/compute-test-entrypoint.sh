#!/bin/sh

# if integration test with lua node
cd /root/permissionless-arbitration && ./lua_node/single_dishonest_entrypoint.lua &
cd ~- && sleep 60
# end of integration test
RUST_LOG="info" target/release/dave-compute
