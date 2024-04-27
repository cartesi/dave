Run the following command to generate timing constants based on the program and user's machine performance:

```
docker build -t cartesi/measure_script . && docker run --rm --env MACHINE_PATH="" cartesi/measure_script:latest
```

Valid value for `MACHINE_PATH` can be:

-   `simple-program`
-   `doom-compute-machine`
-   `debootstrap-machine-sparsed`

There are two values in the script that can be configured (WIP):

-   `root_tournament_slowdown`:
    This is what the user (you) finds acceptable as slowdown for the root tournament. In other words, whichever stride the script chooses for the root tournament, calculating the commitment cannot slow the machine more than `root_tournament_slowdown` when compared with just calculating the final state. Default it to 2.5 slowdown with the reference machine. For rollups it can be 5.0.
-   `inner_tournament_timeout`:
    This is the timeout for the computation effort. This value is chosen by the user. Set the timeout you want, and the script will adapt the other values as a function of this nested_tournament_timeout. If it's set too low, it's possible the script might not work, or that it will need a lot of levels.
    Default it to 5 minutes, got ok results on the reference machine. For rollups, it could be set to one hour.

After running the script one should get results like this:

```
level    3
log2_stride    {37, 20, 0}
height    {26, 17, 20}
```

Go to `permissionless-arbitration/contracts` and modified the content of `src/CanonicalConstants.sol`:

-   replace `uint64 constant LEVELS` with the `level` value from the above result
-   replace `uint64[LEVELS] memory arr` from `log2step` function with the `log2_stride` values from the above result
-   replace `uint64[LEVELS] memory arr` from `height` function with the `height` values from the above result
