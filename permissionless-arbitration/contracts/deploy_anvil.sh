#!/bin/bash
RPC_URL="http://127.0.0.1:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
CONCRETE_FACTORIES=("SingleLevelTournamentFactory" \
                    "TopTournamentFactory" \
                    "MiddleTournamentFactory" \
                    "BottomTournamentFactory")

deployed_factories=()
for factory in ${CONCRETE_FACTORIES[@]}; do
    deployed_at=`forge create $factory --rpc-url=$RPC_URL --private-key=$PK | \
                grep "Deployed to: " | \
                tr -d '\n' | \
                tail -c 42`
    deployed_factories+=($deployed_at)
done

deployed_at=`forge create TournamentFactory --rpc-url=$RPC_URL --private-key=$PK --constructor-args \
    ${deployed_factories[0]} \
    ${deployed_factories[1]} \
    ${deployed_factories[2]} \
    ${deployed_factories[3]} | \
    grep "Deployed to: " | \
    tr -d '\n' | \
    tail -c 42`

cd ../lua_node/program/
initial_hash=`xxd -p -c32 simple-program/hash`
cd -

cast send --private-key=$PK --rpc-url=$RPC_URL $deployed_at "instantiateTop(bytes32)" 0x$initial_hash
