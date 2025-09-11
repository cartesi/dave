import { getUnixTime, subMinutes } from "date-fns";
import { keccak256 } from "viem";
import type {
    Application,
    Epoch,
    Match,
    MatchAction,
    Tournament,
} from "../components/types";
import { generateMatchID, generateTournamentId } from "./util";

export type EpochWithTournament = Epoch & { tournament?: Tournament };
export type ApplicationEpochs = Application & { epochs: EpochWithTournament[] };

export const dummyMatch: Match = {
    actions: [],
    id: keccak256("0x1"),
    claim1: { hash: keccak256("0x2") },
    claim2: { hash: keccak256("0x3") },
    timestamp: 0,
};

const currentDate = new Date();

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
                    id: generateTournamentId(0, 1_345_972_719),
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
                    id: generateTournamentId(1_345_972_719, 3_220_829_192),
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
                    id: generateTournamentId(3_220_829_192, 5_911_918_810),
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
                    id: generateTournamentId(5_911_918_810, 9_918_817_817),
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
                                        timestamp: getUnixTime(
                                            subMinutes(currentDate, 120 - i),
                                        ),
                                        direction: i % 2 === 0 ? 0 : 1,
                                    }),
                                ),
                                {
                                    type: "match_sealed_inner_tournament_created",
                                    range: [7_102_817_919, 7_402_918_071],
                                    timestamp: getUnixTime(
                                        subMinutes(currentDate, 50),
                                    ),
                                },
                            ],
                            id: generateMatchID(
                                keccak256("0x4"),
                                keccak256("0x5"),
                            ),
                            claim1: { hash: keccak256("0x4") },
                            claim2: { hash: keccak256("0x5") },
                            timestamp: 0,
                            tournament: {
                                id: generateTournamentId(
                                    7_102_817_919,
                                    7_402_918_071,
                                ),
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
                                                    timestamp: getUnixTime(
                                                        subMinutes(
                                                            currentDate,
                                                            30 - i,
                                                        ),
                                                    ),
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
                                                timestamp: getUnixTime(
                                                    subMinutes(currentDate, 2),
                                                ),
                                            },
                                        ],
                                        id: generateMatchID(
                                            keccak256("0x6"),
                                            keccak256("0x7"),
                                        ),
                                        claim1: { hash: keccak256("0x6") },
                                        claim2: { hash: keccak256("0x7") },
                                        timestamp: 0,
                                        tournament: {
                                            id: generateTournamentId(
                                                7_204_918_919,
                                                7_205_024_571,
                                            ),
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
