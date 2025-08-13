import type { Meta, StoryObj } from "@storybook/react-vite";
import {
    concat,
    hexToNumber,
    keccak256,
    slice,
    toBytes,
    zeroAddress,
    type Hex,
} from "viem";
import type { Claim, Match, Round } from "../../components/types";
import { TournamentPage } from "../../view/tournament/Tournament";
import {
    Closed,
    NoChallengerYet,
    Ongoing,
} from "../Components/Tournament.stories";
import { applications, epochs } from "../data";

const meta = {
    title: "Pages/Tournament",
    component: TournamentPage,
} satisfies Meta<typeof TournamentPage>;

export default meta;
type Story = StoryObj<typeof meta>;

export const TopLevelSealed: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: NoChallengerYet.args.tournament,
    },
};

export const TopLevelClosed: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[3],
        tournament: Closed.args.tournament,
    },
};

export const TopLevelDispute: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: Ongoing.args.tournament,
    },
};

/**
 * Return a number between 0 and 1 from a hex value.
 * @param value hex value with arbitrary length
 * @returns number between 0 and 1
 */
const hexToFraction = (value: Hex): number => {
    const l = slice(value, 0, 1);
    const n = hexToNumber(l);
    return n / 256;
};

/**
 * Generate a random winner for a match, 20% chance of undefined, 40% chance of 1, 40% chance of 2
 * @returns
 */
const randomWinner = (claim1: Claim, claim2: Claim): 1 | 2 | undefined => {
    const r = hexToFraction(keccak256(concat([claim1.hash, claim2.hash])));
    if (r < 0.2) return undefined;
    if (r < 0.6) return 1;
    return 2;
};

/**
 * Create random claims
 */
const startTimestamp = Math.floor(Date.now() / 1000) * 1000;
const amountOfClaims = 128 as const;
const rootClaims: Claim[] = Array.from({ length: amountOfClaims }).map(
    (_, i) => ({
        hash: keccak256(toBytes(i)),
        claimer: zeroAddress,
        timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
    }),
);

/**
 * Pair up claims, and assign a random winner to each match
 * @param claims list of claims to pair up
 * @param ongoingPreviousRound number of ongoing matches in the previous round
 * @returns
 */
const pairUp = (claims: Claim[]): Match[] => {
    const matches: Match[] = [];
    for (let i = 0; i < claims.length; i += 2) {
        const claim1 = claims[i];
        const claim2 = claims[i + 1]; // will be undefined if number of claims is odd

        matches.push({
            claim1,
            claim2,
            claim1Timestamp: claim1.timestamp,
            claim2Timestamp: claim2?.timestamp,
        });
    }
    return matches;
};

const next = (
    round: Round,
    ongoingPreviousRounds: number,
): Round | undefined => {
    const matches: Match[] = [];

    for (const match of round.matches) {
        // declare a random winner
        // orphans are only declared as winner if there are no ongoing matches in previous rounds
        const winner = match.claim2
            ? randomWinner(match.claim1, match.claim2)
            : ongoingPreviousRounds > 0
              ? undefined
              : 1;

        if (winner !== undefined) {
            // if a winner has been declared, set winner and timestamp
            match.winner = winner;
            match.winnerTimestamp = match.claim2Timestamp
                ? match.claim2Timestamp + 1000
                : match.claim1Timestamp + 1000;

            const winnerClaim =
                winner === 1 ? match.claim1 : (match.claim2 as Claim);

            // get the last match of the new round
            const lastMatch = matches[matches.length - 1];

            if (lastMatch && !lastMatch.claim2) {
                // if there is a match with a free slot, add the winner as claim2
                lastMatch.claim2 = winnerClaim;
                lastMatch.claim2Timestamp = match.winnerTimestamp;
            } else {
                // create a new match with the winner as claim1
                matches.push({
                    claim1: winnerClaim,
                    claim1Timestamp: match.winnerTimestamp,
                });
            }
        }
    }

    return matches.length > 0 ? { matches } : undefined;
};

let ongoing = 0; // accumulator for the amount of ongoing matches
const rounds: Round[] = [];

/**
 * Create rounds until there are only ongoing matches
 */
let round: Round | undefined = { matches: pairUp(rootClaims) };
rounds.push(round);
do {
    round = next(round, ongoing);
    if (round) {
        // increment the number of matches that are still ongoing
        ongoing += round.matches.filter(
            (match) => match.winner === undefined,
        ).length;

        // add the round to the list of rounds
        rounds.push(round);
    }
} while (round);

let winner: Claim | undefined;
if (ongoing === 0) {
    // all matches are resolved, the winner is the last surviving claim, in last round
    const lastRound = rounds[rounds.length - 1];
    const lastMatch = lastRound.matches[0];
    winner =
        lastMatch.winner === 1
            ? lastMatch.claim1
            : lastMatch.winner === 2
              ? lastMatch.claim2
              : undefined;
}

export const TopLevelLargeDispute: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: {
            level: "TOP",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            rounds,
            winner,
        },
    },
};
