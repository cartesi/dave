import { and, eq } from 'ponder';
import { ponder } from 'ponder:registry';
import { match } from 'ponder:schema';
import { generateMatchID, shouldSkipTournamentEvent } from './utils';

const TOURNAMENT_LEVEL = 2n as const;

ponder.on('BottomTournament:matchCreated', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const { leftOfTwo, one, two } = event.args;

    const matchId = generateMatchID(one, two);
    const { timestamp } = event.block;

    await context.db.insert(match).values({
        id: matchId,
        commitmentOne: one,
        commitmentTwo: two,
        leftOfTwo,
        timestamp,
        tournamentId: tournamentAddress,
    });

    console.log(
        `->->(BottomTournament:matchCreated) \n\t\tone:${event.args.one} \n\t\ttwo: ${event.args.two} \n\t\tlNodeTwo:${event.args.leftOfTwo}`,
    );
});

ponder.on('BottomTournament:matchDeleted', async ({ event, context }) => {
    const { address: tournamentAddress } = event.log;
    const skip = await shouldSkipTournamentEvent(
        tournamentAddress,
        context,
        TOURNAMENT_LEVEL,
    );

    if (skip) return;

    const [matchIdHash] = event.args;

    const result = await context.db.sql
        .update(match)
        .set({ status: 'FINISHED' })
        .where(
            and(
                eq(match.id, matchIdHash),
                eq(match.tournamentId, tournamentAddress),
            ),
        );

    console.log(`-> Update result: (${result})`);
    console.log(
        `->->(BottomTournament:matchDeleted) \n\t\tmatchId: ${matchIdHash}`,
    );
});
