# PRT Compute in Lua

This directory contains a prototype node written in Lua.
The purpose of this Lua node is testing and prototyping only; the real production node is written in Rust.
Furthermore, this node implements only compute (_i.e._ a one-shot computation, the machine doesn't yield for inputs).

Remember to either clone the repository with the flag `--recurse-submodules`, or run `git submodule update --recursive --init` after cloning.
You need a docker installation to run the Dave Lua node.

## Build test image

In order to run tests in this directory, machine images must be built with docker to prepare the test environment.
Once the test image is built, the user can run all the tests supported by swapping the `MACHINE_PATH` env variable.

```bash
just build-programs
```

## Run simple test

This directory also has an example _verification tournament_ program, in which players compete against each other to prove the correct result of a computation.
The computation binary is specified in the [`programs`](programs) directory.
From this binary, the example program first generates a Cartesi Machine image, which fully specifies a computation.
Then, it creates a local blockchain and deploys all the Dave smart contracts to it.
Finally, it spawns multiple players to fight each other.

Note that there may only be one instance of each claim (_i.e._ no duplicates).
Players that are defending the same claim will join forces.
These players come in multiple flavours:

- The honest player is one that uses the honest strategy and defends the correct claim.
    The honest players will always emerge victorious.
    There may be multiple honest players; they'll help each other defending the correct claim.
    Honest players never fight multiple matches at the same time.
- One kind of dishonest player uses the honest strategy, but defends an incorrect claim.
    These dishonest players will always lose a match against the correct claim.
- Another kind of dishonest player — called the _idle_ player — posts a claim, but never interacts with the blockchain again.
    If no other player is actively defending this claim, it will lose by timeout.

To add more players of different kinds, you can edit the [`prt_compute.lua`](prt_compute.lua) file.
To run the full example, execute one of the following commands from the current path:

## Run simple test

A [simple program](./programs/simple/README.md) is provided to test the compute.

```bash
just test-simple
```

## Run doom test

A [doom program](./programs/doom/README.md) is provided to test the compute.

```bash
just test-doom
```

## Run stress test

A [debootstrap program](./programs/stress/README.md) is provided to test the compute.

```bash
just test-stress
```

## Read node logs

To get more information of the honest player's machine execution in a separate terminal

```bash
just read-node-logs
```
