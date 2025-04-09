import { and, eq, or } from 'ponder';
import { ponder } from 'ponder:registry';
import { Commitment, Match, Step, Tournament } from 'ponder:schema';
import { decodeFunctionData, getAbiItem } from 'viem';
import {
    CommitmentEvent,
    commitmentJoinedHandler,
} from './handlers/commitmentJoinedHandler';
import { nonLeafTournamentEventNames } from './handlers/commons';
import { generateId, generateMatchID, stringifyContent } from './utils';
import createLogger, { generateEventLoggers } from './utils/logger';

const topTournamentLogger = createLogger(
    'TopTournament',
    'top-tournament-indexing-fn',
);

const loggers = generateEventLoggers(
    nonLeafTournamentEventNames,
    topTournamentLogger,
);

ponder.on('TopTournament:commitmentJoined', async ({ event, context }) => {
    const abi = context.contracts.TopTournament.abi;
    const joinTournament = getAbiItem({ abi, name: 'joinTournament' });
    const { args } = decodeFunctionData<readonly [typeof joinTournament]>({
        abi: [joinTournament],
        data: event.transaction.input,
    });
    const [machineHash, proof, leftNode, rightNode] = args;
    const logger = loggers['commitmentJoined'];

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
        logger: logger,
    }).catch((err) => logger.error(err));
});

ponder.on('TopTournament:matchCreated', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const { leftOfTwo, one, two } = event.args;

    const matchId = generateMatchID(one, two);
    const logger = loggers['matchCreated'];

    await context.db.insert(Match).values({
        id: matchId,
        commitmentOne: one,
        commitmentTwo: two,
        leftOfTwo,
        timestamp: event.block.timestamp,
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

ponder.on('TopTournament:matchAdvanced', async ({ event, context }) => {
    const abi = context.contracts.TopTournament.abi;
    const advanceMatch = getAbiItem({ abi, name: 'advanceMatch' });
    const logger = loggers['matchAdvanced'];
    const { args } = decodeFunctionData<readonly [typeof advanceMatch]>({
        abi: [advanceMatch],
        data: event.transaction.input,
    });

    const [commitments, leftNode, rightNode, newLeftNode, newRightNode] = args;

    const [matchIdHash, parentNodeHash, leftNodeHash] = event.args;
    const tournamentAddress = event.log.address;
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

ponder.on('TopTournament:matchDeleted', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const [matchIdHash] = event.args;
    const { client } = context;
    const logger = loggers['matchDeleted'];

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

    logger.info(`matchId(${matchIdHash})`);

    if (game) {
        const [hasResult, commitmentRoot, machineHash] =
            await client.readContract({
                abi: context.contracts.TopTournament.abi,
                address: tournamentAddress,
                functionName: 'arbitrationResult',
            });

        logger.info(`hasArbitrationResult(${hasResult})`);

        if (hasResult) {
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

            const promises = players.map((player) => {
                const status =
                    player.commitmentHash === commitmentRoot &&
                    player.machineHash === machineHash
                        ? 'WON'
                        : 'LOST';

                return context.db
                    .update(Commitment, { id: player.id })
                    .set({ status });
            });

            await Promise.all(promises).catch((error) => {
                console.error(error);
            });

            logger.info(
                `arbitrationResult(${stringifyContent([hasResult, commitmentRoot, machineHash])}`,
            );
        }
    }
});

ponder.on('TopTournament:newInnerTournament', async ({ event, context }) => {
    const [matchIdHash, innerTournamentAddress] = event.args;
    const parentTournament = event.log.address;
    const logger = loggers['newInnerTournament'];

    await context.db.insert(Tournament).values({
        id: innerTournamentAddress,
        level: 1n,
        timestamp: event.block.timestamp,
        matchId: matchIdHash,
        parentId: parentTournament,
    });

    logger
        .info(`innerTournamentAddress(${innerTournamentAddress})`)
        .info(`originFromMatchId(${matchIdHash})`);
});
