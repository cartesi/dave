import { onchainEnum, onchainTable, relations } from 'ponder';

export const matchStatus = onchainEnum('match_status', ['STARTED', 'FINISHED']);
export const commitmentStatus = onchainEnum('commitment_status', [
    'WAITING',
    'PLAYING',
    'WON',
    'LOST',
]);

export const TournamentTable = onchainTable('tournament', (t) => ({
    id: t.hex().primaryKey(),
    timestamp: t.bigint().notNull(),
    level: t.bigint().default(0n),
    parentId: t.hex(),
    matchId: t.hex(),
}));

//matchCreated(p1_keccak256(lNode + rNode), p2_keccak256(lnode + rnode), p2LeftNodeHash)
export const MatchTable = onchainTable('match', (t) => ({
    id: t.hex().primaryKey(),
    commitmentOne: t.hex().notNull(),
    commitmentTwo: t.hex().notNull(),
    leftOfTwo: t.hex().notNull(),
    status: matchStatus('match_status').default('STARTED'),
    tournamentId: t.hex().notNull(),
    timestamp: t.bigint().notNull(),
}));

// represent matchAdvanced(matchId_hash, parent_node_hash, left_node_hash)
export const StepTable = onchainTable('step', (t) => ({
    id: t.hex().primaryKey(),
    advancedBy: t.hex().notNull(),
    parentNodeHash: t.hex().notNull(),
    leftNodeHash: t.hex().notNull(),
    matchId: t.hex().notNull(),
    timestamp: t.bigint().notNull(),
    input: t.jsonb().notNull(),
}));

// commitmentJoined(rootHash(keccak256(lNode, rNode)))
// holds information about the sender, transaction and event-emitted
// Adding the machine-hash when for matching arbitration result after a game is finished
export const CommitmentTable = onchainTable('commitment', (t) => ({
    id: t.hex().primaryKey(),
    commitmentHash: t.hex().notNull(),
    status: commitmentStatus('commitment_status').default('WAITING'),
    timestamp: t.bigint().notNull(),
    tournamentId: t.hex().notNull(),
    matchId: t.hex(),
    // tx information
    playerAddress: t.hex().notNull(),
    machineHash: t.hex().notNull(),
    proof: t.jsonb().notNull(),
    lNode: t.hex().notNull(),
    rNode: t.hex().notNull(),
}));

export const tournamentRelations = relations(
    TournamentTable,
    ({ many, one }) => ({
        parent: one(TournamentTable, {
            fields: [TournamentTable.parentId],
            references: [TournamentTable.id],
        }),
        innerTournaments: many(TournamentTable),
        matches: many(MatchTable),
        commitments: many(CommitmentTable),
    }),
);

export const commitmentRelations = relations(CommitmentTable, ({ one }) => ({
    tournament: one(TournamentTable, {
        fields: [CommitmentTable.tournamentId],
        references: [TournamentTable.id],
    }),
    match: one(MatchTable, {
        fields: [CommitmentTable.matchId],
        references: [MatchTable.id],
    }),
}));

export const matchesRelations = relations(MatchTable, ({ one, many }) => ({
    tournament: one(TournamentTable, {
        fields: [MatchTable.tournamentId],
        references: [TournamentTable.id],
    }),
    steps: many(StepTable),
}));

export const stepsRelations = relations(StepTable, ({ one }) => ({
    match: one(MatchTable, {
        fields: [StepTable.matchId],
        references: [MatchTable.id],
    }),
}));
