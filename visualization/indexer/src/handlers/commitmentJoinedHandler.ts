import { and, eq, or } from 'ponder';
import { CommitmentTable, MatchTable } from 'ponder:schema';
import { Address, Hex } from 'viem';
import { generateId } from '../utils';
import { HandlerParams } from './commons';

export interface CommitmentEvent {
    playerCommitment: Hex;
    tournament: Address;
    player: Address;
    timestamp: bigint;
    transaction: {
        machineHash: Hex;
        proof: readonly Hex[];
        leftNode: Hex;
        rightNode: Hex;
    };
}

export const commitmentJoinedHandler = async ({
    context,
    meta,
    logger,
}: HandlerParams<CommitmentEvent>) => {
    const { transaction, player, playerCommitment, tournament, timestamp } =
        meta;

    // The events are in a non-logical order, so match-created is preceding the second player joining.
    // Therefore, we make sure the second player has correct status and match-id set in the commitment table.
    const game = await context.db.sql.query.MatchTable.findFirst({
        where: and(
            eq(MatchTable.tournamentId, tournament),
            or(
                eq(MatchTable.commitmentOne, playerCommitment),
                eq(MatchTable.commitmentTwo, playerCommitment),
            ),
        ),
    });

    if (game) {
        logger.info(`match_found -> matchId(${game.id})`);
    }

    const id = generateId([playerCommitment, tournament]);

    await context.db.insert(CommitmentTable).values({
        id,
        commitmentHash: playerCommitment,
        timestamp: timestamp,
        playerAddress: player,
        lNode: transaction.leftNode,
        rNode: transaction.rightNode,
        proof: transaction.proof,
        machineHash: transaction.machineHash,
        status: game !== undefined ? 'PLAYING' : 'WAITING',
        matchId: game?.id,
        tournamentId: tournament,
    });

    logger
        .info(`root(${playerCommitment})`)
        .info(`playerAddress(${player})`)
        .info(`joinedTournament(${tournament})`);
};
