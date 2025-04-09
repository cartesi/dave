import { and, eq, or } from 'ponder';
import { ponder } from 'ponder:registry';
import { commitment, match, step, tournament } from 'ponder:schema';
import { decodeFunctionData, getAbiItem } from 'viem';
import { generateId, generateMatchID, stringifyContent } from './utils';

ponder.on('TopTournament:commitmentJoined', async ({ event, context }) => {
    const playerCommitment = event.args.root;
    const tournamentAddress = event.log.address;
    const playerAddress = event.transaction.from;

    const abi = context.contracts.TopTournament.abi;
    const joinTournament = getAbiItem({ abi, name: 'joinTournament' });
    const { args } = decodeFunctionData<readonly [typeof joinTournament]>({
        abi: [joinTournament],
        data: event.transaction.input,
    });

    const [machineHash, proof, leftNode, rightNode] = args;

    // The events are in a non-logical order, so match-created is preceding the second player joining.
    // Therefore, we make sure the second player has correct status and match-id set in the commitment table.
    const game = await context.db.sql.query.match.findFirst({
        where: and(
            eq(match.tournamentId, tournamentAddress),
            or(
                eq(match.commitmentOne, playerCommitment),
                eq(match.commitmentTwo, playerCommitment),
            ),
        ),
    });

    if (game) {
        console.info(
            `->-> (TopTournament:commitmentJoined:match_found) \n\t ${stringifyContent(game)}`,
        );
    }

    const id = generateId([playerCommitment, tournamentAddress]);

    // await context.db.insert(lobbies).values({
    await context.db.insert(commitment).values({
        id,
        commitmentHash: playerCommitment,
        timestamp: event.block.timestamp,
        playerAddress,
        lNode: leftNode,
        rNode: rightNode,
        proof,
        machineHash,
        status: game !== undefined ? 'PLAYING' : 'WAITING',
        matchId: game?.id,
        tournamentId: tournamentAddress,
    });

    console.info(
        `->-> (TopTournament:commitmentJoined) \n\troot(${playerCommitment}) \n\tplayerAddress(${playerAddress}) \n\tjoinedTournament(${tournamentAddress})`,
    );
});

ponder.on('TopTournament:matchCreated', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const { leftOfTwo, one, two } = event.args;

    const matchId = generateMatchID(one, two);

    await context.db.insert(match).values({
        id: matchId,
        commitmentOne: one,
        commitmentTwo: two,
        leftOfTwo,
        timestamp: event.block.timestamp,
        tournamentId: tournamentAddress,
    });

    const updatedRows = await context.db.sql
        .update(commitment)
        .set({ status: 'PLAYING', matchId })
        .where(
            or(
                eq(commitment.id, generateId([one, tournamentAddress])),
                eq(commitment.id, generateId([two, tournamentAddress])),
            ),
        )
        .returning({ id: commitment.id });

    console.info(
        `->-> (TopTournament:matchCreated (${tournamentAddress})) \n\t\tMatchId:${matchId} \n\t\tone:${event.args.one} \n\t\ttwo: ${event.args.two} \n\t\tlNodeTwo:${event.args.leftOfTwo}`,
    );
    console.info(
        `->-> (TopTournament:matchCreated:updated_commitments \n\t\tids:${stringifyContent(updatedRows)}`,
    );
});

ponder.on('TopTournament:matchAdvanced', async ({ event, context }) => {
    const abi = context.contracts.TopTournament.abi;
    const advanceMatch = getAbiItem({ abi, name: 'advanceMatch' });
    const { args } = decodeFunctionData<readonly [typeof advanceMatch]>({
        abi: [advanceMatch],
        data: event.transaction.input,
    });

    const [commitments, leftNode, rightNode, newLeftNode, newRightNode] = args;

    const [matchIdHash, parentNodeHash, leftNodeHash] = event.args;
    const tournamentAddress = event.log.address;
    const playerAddress = event.transaction.from;

    await context.db.insert(step).values({
        id: generateId([matchIdHash, parentNodeHash, leftNodeHash]),
        advancedBy: playerAddress,
        leftNodeHash: leftNodeHash,
        parentNodeHash: parentNodeHash,
        timestamp: event.block.timestamp,
        matchId: matchIdHash,
        input: {
            commitments,
            leftNode,
            rightNode,
            newLeftNode,
            newRightNode,
        },
    });

    console.info(
        `->-> (TopTournament:matchAdvanced: ${tournamentAddress}) \n\t${stringifyContent(event.args)}`,
    );
});

ponder.on('TopTournament:matchDeleted', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const [matchIdHash] = event.args;
    const { client } = context;

    const [game] = await context.db.sql
        .update(match)
        .set({ status: 'FINISHED' })
        .where(
            and(
                eq(match.id, matchIdHash),
                eq(match.tournamentId, tournamentAddress),
            ),
        )
        .returning();

    console.info(
        `->-> (TopTournament:matchDeleted) \n\t\tmatchId: ${matchIdHash}`,
    );

    if (game) {
        const [hasResult, commitmentRoot, machineHash] =
            await client.readContract({
                abi: context.contracts.TopTournament.abi,
                address: tournamentAddress,
                functionName: 'arbitrationResult',
            });

        if (hasResult) {
            const { commitmentOne, commitmentTwo } = game;
            const players = await context.db.sql.query.commitment.findMany({
                where: or(
                    eq(
                        commitment.id,
                        generateId([commitmentOne, tournamentAddress]),
                    ),
                    eq(
                        commitment.id,
                        generateId([commitmentTwo, tournamentAddress]),
                    ),
                ),
                columns: { commitmentHash: true, machineHash: true, id: true },
            });

            const promises = players.map((player) => {
                const status =
                    player.commitmentHash === commitmentRoot &&
                    player.machineHash === machineHash
                        ? 'WON'
                        : 'LOST';

                return context.db
                    .update(commitment, { id: player.id })
                    .set({ status });
            });

            await Promise.all(promises).catch((error) => {
                console.error(error);
            });

            console.info(
                `->-> (TopTournament:arbitrationResult) \n\tmatchId: ${stringifyContent([hasResult, commitmentRoot, machineHash])}`,
            );
        }
    }
});

ponder.on('TopTournament:newInnerTournament', async ({ event, context }) => {
    const [matchIdHash, innerTournamentAddress] = event.args;
    const parentTournament = event.log.address;

    await context.db.insert(tournament).values({
        id: innerTournamentAddress,
        level: 1n,
        timestamp: event.block.timestamp,
        matchId: matchIdHash,
        parentId: parentTournament,
    });

    console.info(
        `->-> (TopTournament:newInnerTournament) \n\tmatchId:${matchIdHash} \n\ttournamentAddress: ${innerTournamentAddress}`,
    );
});
