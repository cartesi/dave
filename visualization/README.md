> This project uses git submodules.
> Remember to either clone the repository with the flag `--recurse-submodules`, or run `just update-submodules` after cloning.

# Visualization [WIP]

Currently you can run a block explorer (otterscan + sourcify) to check what is going on when dave is simulating its Tournament, but first, you should run Dave in a docker container by executing the following command in the root folder (i.e. /dave)

```
just run-dockered just test-rollups-echo
```

## Block Explorer (Anvil Devnet)

After running the above required steps you can open a new shell and inside this folder we have a [justfile](./justfile) to simplify the process to get it up-and-running.

You can execute the following

```just
just up
```

> [!NOTE]  
> This will take care of setting configurations, building a sourcify docker-image and start both otterscan and sourcify using docker.

**You can access Otterscan on http://localhost:5100**.

If Dave is already running and simulating its tournament you can verify a few contracts so it becomes a bit more friendly to the reader.

Execute the following command.

```just
 just validate-contracts
```

> [!NOTE]  
> This will validate a few contracts of interest e.g. TopTournament.sol, a bunch of other contracts that are part of deployment scripts named DaveConsensus.s.sol and InputBox.s.sol.

## Work-in-progress

- Indexer
- User interface to present what is going on during the PRT events.
- Include the dave-node as an service in the docker-compose. (DX)
