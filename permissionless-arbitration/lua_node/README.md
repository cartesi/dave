# Dave Lua node

This directory contains a prototype node written in Lua.
The purpose of this Lua node is testing and prototyping only; the real production node is written in Rust.
Furthermore, this node implements only compute (_i.e._ a one-shot computation, like a rollups with no inputs).

Remember to either clone the repository with the flag `--recurse-submodules`, or run `git submodule update --recursive --init` after cloning.
You need a docker installation to run the Dave Lua node.

## Build test image

In order to run tests in this directory, a docker image must be built to prepare the test environment. Once the test image is built, the user can run all the tests supported by swapping the `MACHINE_PATH` env variable.

```
docker build -t dave:latest -f Dockerfile ../../
```

## Run simple test

This directory also has an example _verification tournament_ program, in which players compete against each other to prove the correct result of a computation.
The computation binary is specified in the [`program`](program) directory.
From this binary, the example program first generates a Cartesi Machine image, which fully specifies a computation.
Then, it creates a local blockchain and deploys all the Dave smart contracts to it.
Finally, it spawns multiple players to fight each other.

Note that there may only be one instance of each claim (_i.e._ no duplicates).
Players that are defending the same claim will join forces.
These players come in multiple flavours:

-   The honest player is one that uses the honest strategy and defends the correct claim.
    The honest players will always emerge victorious.
    There may be multiple honest players; they'll help each other defending the correct claim.
    Honest players never fight multiple matches at the same time.
-   One kind of dishonest player uses the honest strategy, but defends an incorrect claim.
    These dishonest players will always lose a match against the correct claim.
-   Another kind of dishonest player — called the _idle_ player — posts a claim, but never interacts with the blockchain again.
    If no other player is actively defending this claim, it will lose by timeout.

To add more players of different kinds, you can edit the [`self_contained_entrypoint.lua`](self_contained_entrypoint.lua) file.
To run the full example, execute the following command from the current path path (_i.e._ [`permissionless-arbitration/lua_node`](.)):

```
docker run --rm \
    --env MACHINE_PATH="/app/lua_node/program/simple-program" \
    --env DEPLOY_TO_ANVIL="true" \
    dave:latest
```

## Run stress test

```
docker run --rm \
    --env MACHINE_PATH="/app/lua_node/program/debootstrap-machine-sparsed" \
    --env DEPLOY_TO_ANVIL="true" \
    dave:latest
```

## Run doom showcase

```
docker run --rm \
    --env MACHINE_PATH="/app/lua_node/program/doom-compute-machine" \
    --env DEPLOY_TO_ANVIL="true" \
    dave:latest
```

## Run doom showcase with graphics on

```
mkdir -p snapshots
docker run --rm \
    --env MACHINE_PATH="/app/lua_node/program/doom-compute-machine" \
    --env DEPLOY_TO_ANVIL="true" \
    --mount type=bind,source="$(pwd)/snapshots",target=/app/snapshots \
    dave:latest graphics
```

On a separate terminal run the script to view the actual game graphics while being disputed:
```
sudo ./doom_showcase/view.sh
```

[`mplayer`](http://www.mplayerhq.hu/design7/news.html) is required to run the game graphics.

`sudo` may be required as the files are created inside the docker container.
