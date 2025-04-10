import { and, eq, or } from 'ponder';
import { ponder } from 'ponder:registry';
import {
    CommitmentTable,
    MatchTable,
    StepTable,
    TournamentTable,
} from 'ponder:schema';
import { decodeFunctionData, getAbiItem } from 'viem';
import {
    CommitmentEvent,
    commitmentJoinedHandler,
} from './handlers/commitmentJoinedHandler';
import { generateId, generateMatchID, stringifyContent } from './utils';
import createLogger from './utils/logger';

const topTournamentLogger = createLogger(
    'TopTournament',
    'top-tournament-indexing-fn',
);
const commitmentLogger = topTournamentLogger.child({
    eventName: ':commitmentJoined',
});

ponder.on('TopTournament:commitmentJoined', async ({ event, context }) => {
    const abi = context.contracts.TopTournament.abi;
    const joinTournament = getAbiItem({ abi, name: 'joinTournament' });
    const { args } = decodeFunctionData<readonly [typeof joinTournament]>({
        abi: [joinTournament],
        data: event.transaction.input,
    });
    const [machineHash, proof, leftNode, rightNode] = args;

    const commitment: CommitmentEvent = {
        player: event.transaction.from,
        playerCommitment: event.args.root,
        tournament: event.log.address,
        timestamp: event.block.timestamp,
        transaction: {
            leftNode,
            rightNode,
            machineHash,
            proof,
        },
    };

    await commitmentJoinedHandler({
        context,
        meta: commitment,
        logger: commitmentLogger,
    }).catch((err) => commitmentLogger.error(err));
});

ponder.on('TopTournament:matchCreated', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const { leftOfTwo, one, two } = event.args;

    const matchId = generateMatchID(one, two);

    await context.db.insert(MatchTable).values({
        id: matchId,
        commitmentOne: one,
        commitmentTwo: two,
        leftOfTwo,
        timestamp: event.block.timestamp,
        tournamentId: tournamentAddress,
    });

    const updatedRows = await context.db.sql
        .update(CommitmentTable)
        .set({ status: 'PLAYING', matchId })
        .where(
            or(
                eq(CommitmentTable.id, generateId([one, tournamentAddress])),
                eq(CommitmentTable.id, generateId([two, tournamentAddress])),
            ),
        )
        .returning({ id: CommitmentTable.id });

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

    await context.db.insert(StepTable).values({
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

    console.info(`->-> (TopTournament:matchAdvanced: ${tournamentAddress})`);
});

ponder.on('TopTournament:matchDeleted', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const [matchIdHash] = event.args;
    const { client } = context;

    const [game] = await context.db.sql
        .update(MatchTable)
        .set({ status: 'FINISHED' })
        .where(
            and(
                eq(MatchTable.id, matchIdHash),
                eq(MatchTable.tournamentId, tournamentAddress),
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
            const players = await context.db.sql.query.CommitmentTable.findMany(
                {
                    where: or(
                        eq(
                            CommitmentTable.id,
                            generateId([commitmentOne, tournamentAddress]),
                        ),
                        eq(
                            CommitmentTable.id,
                            generateId([commitmentTwo, tournamentAddress]),
                        ),
                    ),
                    columns: {
                        commitmentHash: true,
                        machineHash: true,
                        id: true,
                    },
                },
            );

            const promises = players.map((player) => {
                const status =
                    player.commitmentHash === commitmentRoot &&
                    player.machineHash === machineHash
                        ? 'WON'
                        : 'LOST';

                return context.db
                    .update(CommitmentTable, { id: player.id })
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

    await context.db.insert(TournamentTable).values({
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
