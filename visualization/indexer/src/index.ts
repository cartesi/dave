import { ponder } from 'ponder:registry';
import { Tournament } from 'ponder:schema';
import createLogger from './utils/logger';

const logger = createLogger(
    'MultiLevelTournamentFactory',
    'multi-level-tournament-factory-indexing-fn',
    'info',
    { eventName: ':tournamentCreated' },
);

ponder.on(
    'MultiLevelTournamentFactory:tournamentCreated',
    async ({ event, context }) => {
        const [topTournamentAddress] = event.args;

        await context.db.insert(Tournament).values({
            id: topTournamentAddress,
            level: 0n,
            timestamp: event.block.timestamp,
        });

        logger
            .info(`tournamentAddress(${topTournamentAddress})`)
            .info(`block-number(${event.block.number})`)
            .info(`block-time(${event.block.timestamp})`)
            .info(`from(${event.transaction.from})`)
            .info(`to(${event.transaction.to})`);
    },
);
