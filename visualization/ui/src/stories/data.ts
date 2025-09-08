import { keccak256 } from "viem";
import type {
    Application,
    Epoch,
    MatchAction,
    Tournament,
} from "../components/types";

export type EpochWithTournament = Epoch & { tournament?: Tournament };
export type ApplicationEpochs = Application & { epochs: EpochWithTournament[] };

export const applications: ApplicationEpochs[] = [
    {
        address: "0x4c1E74EF88a75C24e49eddD9f70D82A94D19251c",
        name: "honeypot",
        consensusType: "PRT",
        state: "ENABLED",
        processedInputs: 8,
        epochs: [
            {
                index: 0,
                inDispute: false,
                status: "FINALIZED",
                tournament: {
                    startCycle: 0,
                    endCycle: 1_345_972_719,
                    height: 48,
                    level: "top",
                    matches: [],
                    danglingClaim: { hash: keccak256("0x1") },
                    winner: { hash: keccak256("0x1") },
                },
            },
            {
                index: 1,
                inDispute: false,
                status: "FINALIZED",
                tournament: {
                    startCycle: 1_345_972_719,
                    endCycle: 3_220_829_192,
                    height: 48,
                    level: "top",
                    matches: [],
                    danglingClaim: { hash: keccak256("0x2") },
                    winner: { hash: keccak256("0x2") },
                },
            },
            {
                index: 2,
                inDispute: false,
                status: "FINALIZED",
                tournament: {
                    startCycle: 3_220_829_192,
                    endCycle: 5_911_918_810,
                    height: 48,
                    level: "top",
                    matches: [],
                    danglingClaim: { hash: keccak256("0x3") },
                    winner: { hash: keccak256("0x3") },
                },
            },
            {
                index: 3,
                inDispute: true,
                status: "CLOSED",
                tournament: {
                    startCycle: 5_911_918_810,
                    endCycle: 9_918_817_817,
                    height: 48,
                    level: "top",
                    matches: [
                        {
                            actions: [
                                ...Array.from<number, MatchAction>(
                                    { length: 48 },
                                    (_, i) => ({
                                        type: "advance",
                                        timestamp: i,
                                        direction: i % 2 === 0 ? 0 : 1,
                                    }),
                                ),
                                {
                                    type: "match_sealed_inner_tournament_created",
                                    range: [7_102_817_919, 7_402_918_071],
                                    timestamp: 0,
                                },
                            ],
                            claim1: { hash: keccak256("0x4") },
                            claim2: { hash: keccak256("0x5") },
                            timestamp: 0,
                            tournament: {
                                startCycle: 7_102_817_919,
                                endCycle: 7_402_918_071,
                                height: 27,
                                level: "middle",
                                matches: [
                                    {
                                        actions: [
                                            ...Array.from<number, MatchAction>(
                                                { length: 27 },
                                                (_, i) => ({
                                                    type: "advance",
                                                    timestamp: i,
                                                    direction:
                                                        i % 2 === 0 ? 0 : 1,
                                                }),
                                            ),
                                            {
                                                type: "match_sealed_inner_tournament_created",
                                                range: [
                                                    7_204_918_919,
                                                    7_205_024_571,
                                                ],
                                                timestamp: 0,
                                            },
                                        ],
                                        claim1: { hash: keccak256("0x6") },
                                        claim2: { hash: keccak256("0x7") },
                                        timestamp: 0,
                                        tournament: {
                                            startCycle: 7_204_918_919,
                                            endCycle: 7_205_024_571,
                                            height: 17,
                                            level: "bottom",
                                            matches: [],
                                            danglingClaim: {
                                                hash: keccak256("0x8"),
                                            },
                                            winner: { hash: keccak256("0x8") },
                                        },
                                    },
                                ],
                            },
                        },
                    ],
                },
            },
            {
                index: 4,
                inDispute: false,
                status: "OPEN",
            },
        ],
    },
    {
        address: "0x1590B6096A48A509286cdec2cb68E0DF292BFEf6",
        name: "comet",
        consensusType: "AUTHORITY",
        state: "ENABLED",
        processedInputs: 100,
        epochs: [],
    },
    {
        address: "0x70ac08179605AF2D9e75782b8DEcDD3c22aA4D0C",
        name: "disabled",
        consensusType: "QUORUM",
        state: "DISABLED",
        processedInputs: 15,
        epochs: [],
    },
    {
        address: "0x7285F04d1d779B77c63F61746C1dDa204E32aE45",
        name: "broken",
        consensusType: "PRT",
        state: "INOPERABLE",
        processedInputs: 45,
        epochs: [],
    },
];
