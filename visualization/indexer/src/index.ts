import { ponder } from 'ponder:registry';
import { tournament } from 'ponder:schema';

ponder.on(
    'MultiLevelTournamentFactory:tournamentCreated',
    async ({ event, context }) => {
        const [topTournamentAddress] = event.args;

        await context.db.insert(tournament).values({
            id: topTournamentAddress,
            level: 0n,
            timestamp: event.block.timestamp,
        });

        console.log(`->->(Tournament Created)`);
        console.log(`\t\ttournamentAddress: ${topTournamentAddress}`);
        console.log(`\t\tblocknumber: ${event.block.number}`);
        console.log(`\t\tblock-timestamp: ${event.block.timestamp}`);
        console.log(`\t\tfrom: ${event.transaction.from}`);
        console.log(`\t\tto: ${event.transaction.to}`);
    },
);
