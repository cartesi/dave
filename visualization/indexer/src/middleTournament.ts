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
import {
    generateId,
    generateMatchID,
    shouldSkipTournamentEvent,
} from './utils';
import createLogger from './utils/logger';

const TOURNAMENT_LEVEL = 1n as const;

const middleLogger = createLogger(
    'MiddleTournament',
    'middle-tournament-indexer-fn',
);

ponder.on('MiddleTournament:commitmentJoined', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = middleLogger.child({ eventName: ':commitmentJoined' });

    const abi = context.contracts.MiddleTournament.abi;
    const joinTournament = getAbiItem({ abi, name: 'joinTournament' });
    const { args } = decodeFunctionData<readonly [typeof joinTournament]>({
        abi: [joinTournament],
        data: event.transaction.input,
    });
    const [machineHash, proof, leftNode, rightNode] = args;

    const commitment: CommitmentEvent = {
        player: event.transaction.from,
        playerCommitment: event.args.root,
        tournament: tournamentAddress,
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
        logger,
    }).catch((err) => logger.error(err));

    logger.close();
});

ponder.on('MiddleTournament:matchCreated', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = middleLogger.child({ eventName: ':matchCreated' });

    const { leftOfTwo, one, two } = event.args;

    const matchId = generateMatchID(one, two);
    const { timestamp } = event.block;

    await context.db.insert(MatchTable).values({
        id: matchId,
        commitmentOne: one,
        commitmentTwo: two,
        leftOfTwo,
        timestamp,
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

    logger
        .info(`one:${one} two: ${two} lNodeTwo:${leftOfTwo}`)
        .info(`ids:[ ${updatedRows.map((r) => r.id).join(', ')} ]`);

    logger.close();
});

ponder.on('MiddleTournament:matchAdvanced', async ({ event, context }) => {
    const tournamentAddress = event.log.address;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = middleLogger.child({ eventName: ':matchAdvanced' });

    const abi = context.contracts.MiddleTournament.abi;
    const advanceMatch = getAbiItem({ abi, name: 'advanceMatch' });
    const { args } = decodeFunctionData<readonly [typeof advanceMatch]>({
        abi: [advanceMatch],
        data: event.transaction.input,
    });

    const [commitments, leftNode, rightNode, newLeftNode, newRightNode] = args;

    const [matchIdHash, parentNodeHash, leftNodeHash] = event.args;
    const playerAddress = event.transaction.from;

    logger.info(
        `tournament(${tournamentAddress}) match(${matchIdHash}) advancedBy(${playerAddress})`,
    );

    const step = await context.db.insert(StepTable).values({
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

    logger.info(`MatchStep(${step.id}) created!`);
});

ponder.on('MiddleTournament:matchDeleted', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = middleLogger.child({ eventName: ':matchDeleted' });

    const [matchIdHash] = event.args;
    const { client } = context;

    logger.info(`match(${matchIdHash}) finished!`);

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

    if (game) {
        const [hasInnerWinner, _parentNode, commitmentRoot] =
            await client.readContract({
                abi: context.contracts.MiddleTournament.abi,
                address: tournamentAddress,
                functionName: 'innerTournamentWinner',
            });
        if (hasInnerWinner) {
            const [_, machineHash] = await client.readContract({
                abi: context.contracts.MiddleTournament.abi,
                address: tournamentAddress,
                functionName: 'getCommitment',
                args: [commitmentRoot],
            });

            logger
                .info(
                    `hasWinner(true) commitmentRoot(${commitmentRoot}) contestedNode(${_parentNode})`,
                )
                .info(`machineHash(${machineHash})`);

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

            logger.info(`commitmentsFound(${players.length})`);

            const promises = players.map((player) => {
                const status =
                    player.commitmentHash === commitmentRoot &&
                    player.machineHash === machineHash
                        ? 'WON'
                        : 'LOST';

                logger.info(
                    `playerCommitment(${player.commitmentHash}) status(${status})`,
                );

                return context.db
                    .update(CommitmentTable, { id: player.id })
                    .set({ status });
            });

            await Promise.all(promises).catch((error) => {
                logger.error(error.message);
            });

            logger.info(`matchId(${game.id}) players updated!`);
        } else {
            logger.info(`matchId(${game.id}) don't have an inner-winner`);
        }
    }

    logger.close();
});

ponder.on('MiddleTournament:newInnerTournament', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = middleLogger.child({ eventName: ':newInnerTournament' });

    const [matchIdHash, leafTournamentAddress] = event.args;

    await context.db.insert(TournamentTable).values({
        id: leafTournamentAddress,
        level: 2n,
        timestamp: event.block.timestamp,
        matchId: matchIdHash,
        parentId: tournamentAddress,
    });

    logger.info(
        `newLeafTournament(${leafTournamentAddress}) from matchId(${matchIdHash})`,
    );
});
