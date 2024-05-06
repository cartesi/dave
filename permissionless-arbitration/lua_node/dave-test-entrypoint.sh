#!/usr/bin/env bash
set -euo pipefail

if [ "$1" == "graphics" ]; then
    # process doom graphics during compute process
    cd lua_node/doom_showcase/ && make
    cd -
    rm -rf /app/snapshots/*
    ./lua_node/doom_showcase/process_doom_graphics.lua &
fi

exec ./lua_node/self_contained_entrypoint.lua
