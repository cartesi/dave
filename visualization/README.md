> This project uses git submodules.
> Remember to either clone the repository with the flag `--recurse-submodules`, or run `just update-submodules` after cloning.

# Visualization [WIP]

> [!IMPORTANT]  
> Make sure to be docker logged with a valid GHCR credential [reference here](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-with-a-personal-access-token-classic) to avoid failure when trying to run the docker-compose.

To be able to run the visualization assuming you are under `/visualization` we have a [justfile](./justfile) to simplify the process to get it up-and-running.

You can execute the following

```just
just up
```

> [!NOTE]  
> This will take care of setting configurations, building a dave and sourcify docker-images, also starting both built images + an otterscan(block explorer) instance.

**You can access Otterscan on http://localhost:5100**.

By the logs you will notice Dave is already running and simulating its tournament, therefore you can verify a few contracts so it becomes a bit more friendly to the reader in case of accessing otterscan.

Execute the following command.

```just
 just validate-contracts
```

> [!NOTE]  
> This will validate a few contracts of interest e.g. TopTournament.sol, a bunch of other contracts that are part of deployment scripts named DaveConsensus.s.sol and InputBox.s.sol.

## Work-in-progress

- Indexer
- User interface to present what is going on during the PRT events.
