import { createConfig, factory } from 'ponder';
import { http, parseAbiItem } from 'viem';

import { BottomTournamentAbi } from './abis/BottomTournament';
import { MiddleTournamentAbi } from './abis/MiddleTournament';
import { MultiLevelTournamentFactoryAbi } from './abis/MultiLevelTournamentFactory';
import { TopTournamentAbi } from './abis/TopTournament';
import addressBook from './address-book';

export default createConfig({
    networks: {
        anvil: {
            chainId: 31337,
            transport: http(process.env.PONDER_RPC_URL_31337),
        },
    },
    contracts: {
        MultiLevelTournamentFactory: {
            network: 'anvil',
            abi: MultiLevelTournamentFactoryAbi,
            address: addressBook[31337].multiLevelTournamentFactory,
            startBlock: 0,
        },
        TopTournament: {
            network: 'anvil',
            abi: TopTournamentAbi,
            address: factory({
                address: addressBook[31337].multiLevelTournamentFactory,
                event: parseAbiItem(
                    'event tournamentCreated(address tournamentAddress)',
                ),
                parameter: 'tournamentAddress',
            }),
            startBlock: 0,
        },
        MiddleTournament: {
            network: 'anvil',
            abi: MiddleTournamentAbi,
            filter: [
                {
                    event: 'commitmentJoined',
                    args: [],
                },
                {
                    event: 'matchCreated',
                    args: {},
                },
                {
                    event: 'matchAdvanced',
                    args: [],
                },
                {
                    event: 'matchDeleted',
                    args: [],
                },
                {
                    event: 'newInnerTournament',
                    args: [],
                },
            ],
            startBlock: 0,
        },
        BottomTournament: {
            network: 'anvil',
            abi: BottomTournamentAbi,
            filter: [
                {
                    event: 'commitmentJoined',
                    args: [],
                },
                {
                    event: 'matchCreated',
                    args: {},
                },
                {
                    event: 'matchAdvanced',
                    args: [],
                },
                {
                    event: 'matchDeleted',
                    args: {},
                },
            ],
            startBlock: 0,
        },
    },
});
