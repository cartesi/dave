import { onchainTable } from 'ponder'

const contracts = [
    'TopTournamentFactory',
    'MiddleTournamentFactory',
    'BottomTournamentFactory',
    'MultiLevelTournamentFactory',
    'InputBox', //not sure about that one!
    'DaveConsensus',
    'TopTournament',
    'MiddleTournament',
    'BottomTournament',
]

export const example = onchainTable('example', (t) => ({
    id: t.text().primaryKey(),
    name: t.text(),
}))
