import { Context } from 'ponder:registry';
import { Logger } from 'winston';

export interface HandlerParams<T> {
    meta: T;
    context: Context;
    logger: Logger;
}

export const nonLeafTournamentEventNames = [
    'commitmentJoined',
    'matchCreated',
    'matchAdvanced',
    'matchDeleted',
    'newInnerTournament',
] as const;

export const leafTournamentEventNames = nonLeafTournamentEventNames.filter(
    (name) => name !== 'newInnerTournament',
);

export type NonLeafTournamentEventName =
    (typeof nonLeafTournamentEventNames)[number];

export type LeafTournamentEventName = (typeof leafTournamentEventNames)[number];
