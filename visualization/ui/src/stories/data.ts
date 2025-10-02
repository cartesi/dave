import {
    addMinutes,
    addSeconds,
    fromUnixTime,
    getUnixTime,
    subMinutes,
} from "date-fns";
import { keccak256, type Hex } from "viem";
import type {
    Application,
    Claim,
    CycleRange,
    Epoch,
    Match,
    MatchAction,
    Tournament,
} from "../components/types";
import { claim, generateMatchID, generateTournamentId } from "./util";

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

// large 40kb proof
const proof = `0x${"00".repeat(1024 * 40)}` as Hex;

const applications: ApplicationEpochs[] = [
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

const getTournamentHeight = (level: Tournament["level"]) => {
    switch (level) {
        case "top":
            return 48;
        case "middle":
            return 27;
        default:
            return 17;
    }
};

const getNextRange = (level: Tournament["level"]): CycleRange => {
    switch (level) {
        case "top":
            return [7_102_817_919, 7_402_918_071];
        case "middle":
            return [7_204_918_919, 7_205_024_571];
        default:
            throw new Error(`${level} does not create a sub-tournament`);
    }
};

const numberOfClaims = {
    top: 32,
    middle: 24,
    bottom: 16,
};

let tournamentCounter = 1;
let claimCounter = 0;

const getMinutesPerLevel = (level: Tournament["level"]) => {
    switch (level) {
        case "middle":
            return 60;
        case "bottom":
            return 30;
        default:
            return 120;
    }
};

interface Config {
    parentMatches?: Match[];
    now: Date;
    level: Tournament["level"];
}

type TournamentGeneratorParams = {
    startCycle: number;
    endCycle: number;
    level: Tournament["level"];
    parentMatches?: Match[];
    match?: Match;
    now: Date;
};

interface SimulateActionsParams extends Config {
    match: Match;
}

const simulateActions = (config: SimulateActionsParams) => {
    const height = getTournamentHeight(config.level);
    const elapseTime = getMinutesPerLevel(config.level);
    const matchTime = fromUnixTime(config.match.timestamp);
    const actions: MatchAction[] = Array.from({ length: height }, (_, i) => ({
        type: "advance",
        direction: i % 2 === 0 ? 0 : 1,
        timestamp: getUnixTime(subMinutes(matchTime, elapseTime - i)),
    }));

    if (config.level === "bottom") {
        // XXX: Needs to bubble up.
        const winner = actions.length % 2 === 0 ? 1 : 2;
        const lastAction: MatchAction = {
            type: "leaf_match_sealed",
            proof,
            timestamp: getUnixTime(
                subMinutes(matchTime, elapseTime - actions.length),
            ),
            winner,
        };

        actions.push(lastAction);
        config.match.actions = actions;
        config.match.winner = winner;
        config.parentMatches?.forEach((match) => {
            if (!match.winner) {
                match.winner = winner;
                match.actions.push(lastAction);
            }
        });
    } else {
        const nextLevel = config.level === "top" ? "middle" : "bottom";
        const range = getNextRange(config.level);
        actions.push({
            type: "match_sealed_inner_tournament_created",
            range,
            timestamp: getUnixTime(
                subMinutes(matchTime, elapseTime - actions.length),
            ),
        });
        config.match.actions = actions;
        const parentMatches = config.parentMatches ? config.parentMatches : [];
        parentMatches.push(config.match);
        config.match.tournament = generateTournament({
            now: fromUnixTime(config.match.timestamp),
            level: nextLevel,
            startCycle: range[0],
            endCycle: range[1],
            match: config.match,
            parentMatches,
        });
    }
};

const generateMatches = ({ parentMatches = [], now, level }: Config) => {
    const totalClaims = numberOfClaims[level];
    const matches: Match[] = [];
    const claims: Claim[] = Array.from({ length: totalClaims }).map(() =>
        claim(claimCounter++),
    );
    let danglingClaim = undefined;
    let newClaim = claims.shift();
    let nextDatetime = now;
    let matchCounter = 1;

    while (newClaim) {
        if (level === "top") {
            // console.clear();
            console.log(`claims: ${claims.length}`);
        }
        if (danglingClaim) {
            // create a match with the dangling claim
            const claim1 = danglingClaim;
            const match: Match = {
                id: generateMatchID(claim1.hash, newClaim.hash),
                actions: [],
                claim1,
                claim2: newClaim,
                timestamp: getUnixTime(nextDatetime),
            };

            simulateActions({
                level,
                match,
                now: nextDatetime,
                parentMatches,
            });

            matches.push(match);
            danglingClaim = undefined;

            nextDatetime = addMinutes(nextDatetime, 2);

            matchCounter++;

            if (match.winner) {
                match.winnerTimestamp = getUnixTime(nextDatetime);
                nextDatetime = addSeconds(nextDatetime, 27);
                const winnerClaim =
                    match.winner === 1 ? match.claim1 : match.claim2;
                claims.unshift(winnerClaim);
            }
        } else {
            // assign the claim to the dangling slot
            danglingClaim = newClaim;
        }

        newClaim = claims.shift();
    }

    return {
        danglingClaim,
        matches,
    };
};

const generateTournament = (params: TournamentGeneratorParams): Tournament => {
    const tournament: Tournament = {
        id: generateTournamentId(tournamentCounter++, 0),
        startCycle: params.startCycle,
        endCycle: params.endCycle,
        danglingClaim: undefined,
        height: getTournamentHeight(params.level),
        level: params.level,
        matches: [],
    };

    const { danglingClaim, matches } = generateMatches({
        level: params.level,
        now: currentDate,
        parentMatches: params.parentMatches,
    });

    tournament.matches = matches;
    tournament.danglingClaim = danglingClaim;

    return tournament;
};

// XXX: Generate only for the disputed epoch.
applications[0].epochs[3].tournament = generateTournament({
    now: currentDate,
    startCycle: 5_911_918_810,
    endCycle: 9_918_817_817,
    level: "top",
});

export { applications };
