import { and, eq, or } from 'ponder';
import { ponder } from 'ponder:registry';
import { Commitment, Match, Step, Tournament } from 'ponder:schema';
import { decodeFunctionData, getAbiItem } from 'viem';
import {
    CommitmentEvent,
    commitmentJoinedHandler,
} from './handlers/commitmentJoinedHandler';
import { nonLeafTournamentEventNames } from './handlers/commons';
import {
    generateId,
    generateMatchID,
    shouldSkipTournamentEvent,
    stringifyContent,
} from './utils';
import createLogger, { generateEventLoggers } from './utils/logger';

const TOURNAMENT_LEVEL = 1n as const;

const middleLogger = createLogger(
    'MiddleTournament',
    'middle-tournament-indexer-fn',
);

const loggers = generateEventLoggers(nonLeafTournamentEventNames, middleLogger);

ponder.on('MiddleTournament:commitmentJoined', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = loggers['commitmentJoined'];

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
});

ponder.on('MiddleTournament:matchCreated', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = loggers['matchCreated'];

    const { leftOfTwo, one, two } = event.args;

    const matchId = generateMatchID(one, two);
    const { timestamp } = event.block;

    await context.db.insert(Match).values({
        id: matchId,
        commitmentOne: one,
        commitmentTwo: two,
        leftOfTwo,
        timestamp,
        tournamentId: tournamentAddress,
    });

    const updatedRows = await context.db.sql
        .update(Commitment)
        .set({ status: 'PLAYING', matchId })
        .where(
            or(
                eq(Commitment.id, generateId([one, tournamentAddress])),
                eq(Commitment.id, generateId([two, tournamentAddress])),
            ),
        )
        .returning({ id: Commitment.id });

    logger
        .info(`tournamentAddress(${tournamentAddress})`)
        .info(`matchId(${matchId})`)
        .info(`commitmentOne(${one})`)
        .info(`commitmentTwo(${two})`)
        .info(`lNodeTwo(${leftOfTwo})`)
        .info(`updatedCommitments( ${stringifyContent(updatedRows)} )`);
});

ponder.on('MiddleTournament:matchAdvanced', async ({ event, context }) => {
    const tournamentAddress = event.log.address;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = loggers['matchAdvanced'];

    const abi = context.contracts.MiddleTournament.abi;
    const advanceMatch = getAbiItem({ abi, name: 'advanceMatch' });
    const { args } = decodeFunctionData<readonly [typeof advanceMatch]>({
        abi: [advanceMatch],
        data: event.transaction.input,
    });

    const [commitments, leftNode, rightNode, newLeftNode, newRightNode] = args;

    const [matchIdHash, parentNodeHash, leftNodeHash] = event.args;
    const playerAddress = event.transaction.from;

    await context.db.insert(Step).values({
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

    logger.info(
        `tournament(${tournamentAddress}) match(${matchIdHash}) advancedBy(${playerAddress})`,
    );
});

ponder.on('MiddleTournament:matchDeleted', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = loggers['matchDeleted'];

    const [matchIdHash] = event.args;
    const { client } = context;

    logger.info(`match(${matchIdHash}) finished!`);

    const [game] = await context.db.sql
        .update(Match)
        .set({ status: 'FINISHED' })
        .where(
            and(
                eq(Match.id, matchIdHash),
                eq(Match.tournamentId, tournamentAddress),
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
            const players = await context.db.sql.query.Commitment.findMany({
                where: or(
                    eq(
                        Commitment.id,
                        generateId([commitmentOne, tournamentAddress]),
                    ),
                    eq(
                        Commitment.id,
                        generateId([commitmentTwo, tournamentAddress]),
                    ),
                ),
                columns: {
                    commitmentHash: true,
                    machineHash: true,
                    id: true,
                },
            });

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
                    .update(Commitment, { id: player.id })
                    .set({ status });
            });

            await Promise.all(promises).catch((error) => {
                logger.error(error.message);
            });

            logger.info(`matchId(${game.id}) players updated!`);
        } else {
            logger.info(
                `matchId(${game.id}) don't have an inner-winner decided yet.`,
            );
        }
    }
});

ponder.on('MiddleTournament:newInnerTournament', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const logger = loggers['newInnerTournament'];

    const [matchIdHash, leafTournamentAddress] = event.args;

    await context.db.insert(Tournament).values({
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
