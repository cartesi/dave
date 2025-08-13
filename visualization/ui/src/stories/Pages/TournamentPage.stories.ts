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
const rootClaims: Claim[] = Array.from({ length: 512 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: Date.now(),
}));

/**
 * Pair up claims, and assign a random winner to each match
 * @param claims
 * @returns
 */
const pairUp = (claims: Claim[]): Match[] => {
    const matches: Match[] = [];
    for (let i = 0; i < claims.length; i += 2) {
        const claim1 = claims[i];
        const claim2 = claims[i + 1];
        matches.push({
            claim1,
            claim2,
            winner: !claim2 ? 1 : randomWinner(claim1, claim2),
        });
    }
    return matches;
};

/**
 * Get the winners from a list of matches
 * @param matches
 * @returns
 */
const getWinners = (matches: Match[]): Claim[] => {
    return matches
        .map((match) =>
            match.winner === 1
                ? match.claim1
                : match.winner === 2
                  ? match.claim2
                  : undefined,
        )
        .filter((claim) => !!claim);
};

/**
 * Create rounds until there are only ongoing matches
 */
let claims = rootClaims;
const rounds: Round[] = [];
do {
    const matches = pairUp(claims);
    rounds.push({ matches });
    claims = getWinners(matches);
} while (claims.length > 1);

export const TopLevelLargeDispute: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: {
            level: "TOP",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            rounds,
        },
    },
};
