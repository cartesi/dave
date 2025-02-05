# PRT Rollups test

This tests the rollups Rust node.
The node test will be conducted with a Lua orchestrator script spawning an honest rollups node in the background to advance the rollups states and to defend the application.
The Lua orchestrator script also spawns multiple [dishonest nodes](../compute/README.md) trying to tamper with the rollups states.

Remember to either clone the repository with the flag `--recurse-submodules`, or run `git submodule update --recursive --init` after cloning.
You need a docker installation to run the Dave Lua node.

## Run echo test

A simple [echo program](./program/echo/) is provided to test the rollups.

```bash
just test-echo
```
