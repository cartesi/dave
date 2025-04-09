import { onchainEnum, onchainTable, relations } from 'ponder';

export const matchStatus = onchainEnum('match_status', ['STARTED', 'FINISHED']);
export const commitmentStatus = onchainEnum('commitment_status', [
    'WAITING',
    'PLAYING',
    'WON',
    'LOST',
]);

export const Tournament = onchainTable('tournament', (t) => ({
    id: t.hex().primaryKey(),
    timestamp: t.bigint().notNull(),
    level: t.bigint().default(0n),
    parentId: t.hex(),
    matchId: t.hex(),
}));

//matchCreated(p1_keccak256(lNode + rNode), p2_keccak256(lnode + rnode), p2LeftNodeHash)
export const Match = onchainTable('match', (t) => ({
    id: t.hex().primaryKey(),
    commitmentOne: t.hex().notNull(),
    commitmentTwo: t.hex().notNull(),
    leftOfTwo: t.hex().notNull(),
    status: matchStatus('match_status').default('STARTED'),
    tournamentId: t.hex().notNull(),
    timestamp: t.bigint().notNull(),
}));

// represent matchAdvanced(matchId_hash, parent_node_hash, left_node_hash)
export const Step = onchainTable('step', (t) => ({
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
// Adding the machine-hash for matching arbitration result after a game is finished
export const Commitment = onchainTable('commitment', (t) => ({
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

export const tournamentRelations = relations(Tournament, ({ many, one }) => ({
    parent: one(Tournament, {
        fields: [Tournament.parentId],
        references: [Tournament.id],
    }),
    innerTournaments: many(Tournament),
    matches: many(Match),
    commitments: many(Commitment),
}));

export const commitmentRelations = relations(Commitment, ({ one }) => ({
    tournament: one(Tournament, {
        fields: [Commitment.tournamentId],
        references: [Tournament.id],
    }),
    match: one(Match, {
        fields: [Commitment.matchId],
        references: [Match.id],
    }),
}));

export const matchesRelations = relations(Match, ({ one, many }) => ({
    tournament: one(Tournament, {
        fields: [Match.tournamentId],
        references: [Tournament.id],
    }),
    steps: many(Step),
}));

export const stepsRelations = relations(Step, ({ one }) => ({
    match: one(Match, {
        fields: [Step.matchId],
        references: [Match.id],
    }),
}));
