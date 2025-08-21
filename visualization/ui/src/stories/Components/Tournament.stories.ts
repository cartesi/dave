import type { Meta, StoryObj } from "@storybook/react-vite";
import { fn } from "storybook/test";
import { keccak256, toBytes, zeroAddress } from "viem";
import { TournamentView } from "../../components/tournament/Tournament";
import type { Claim, Tournament } from "../../components/types";
import { randomBisections } from "../util";

const meta = {
    title: "Components/Tournament",
    component: TournamentView,
} satisfies Meta<typeof TournamentView>;

export default meta;
type Story = StoryObj<typeof meta>;

const timestamp = Math.floor(Date.now() / 1000);

const randomClaim = (
    i: number,
    c: Pick<Claim, "timestamp" | "parentClaim">,
): Claim => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: c.timestamp,
    parentClaim: c.parentClaim,
});

const claims: Claim[] = Array.from({ length: 32 }).map((_, i) =>
    randomClaim(i, { timestamp: timestamp + i * 1000 }),
);

const startCycle = 1837880065n;
const endCycle = 2453987565n;

// create 4 bisections of the cycle range
const ranges = randomBisections([startCycle, endCycle], 4, 42);

const tournament: Tournament = {
    level: "TOP",
    startCycle,
    endCycle,
    rounds: [],
};

tournament.rounds.push({
    matches: [
        {
            claim1: randomClaim(0, { timestamp }),
            claim1Timestamp: timestamp,
            claim2: randomClaim(1, { timestamp: timestamp + 1 }),
            claim2Timestamp: timestamp + 1,
            winner: 1,
            winnerTimestamp: timestamp + 2,
            actions: [],
            parentTournament: tournament,
        },
        {
            claim1: randomClaim(2, { timestamp: timestamp + 2 }),
            claim1Timestamp: timestamp + 2,
            claim2: randomClaim(3, { timestamp: timestamp + 3 }),
            claim2Timestamp: timestamp + 3,
            actions: [
                {
                    type: "advance",
                    claimer: 1,
                    range: ranges[0],
                    timestamp: claims[3].timestamp + 1000,
                },
                {
                    type: "advance",
                    claimer: 2,
                    range: ranges[1],
                    timestamp: claims[3].timestamp + 2000,
                },
                {
                    type: "advance",
                    claimer: 1,
                    range: ranges[2],
                    timestamp: claims[3].timestamp + 3000,
                },
                {
                    type: "advance",
                    claimer: 2,
                    range: ranges[3],
                    timestamp: claims[3].timestamp + 4000,
                },
            ],
            parentTournament: tournament,
        },
        {
            claim1: randomClaim(4, { timestamp: timestamp + 4 }),
            claim2: randomClaim(5, { timestamp: timestamp + 5 }),
            winner: 1,
            claim1Timestamp: timestamp + 4,
            claim2Timestamp: timestamp + 5,
            winnerTimestamp: timestamp + 6,
            actions: [],
            parentTournament: tournament,
        },
        {
            claim1: randomClaim(6, { timestamp: timestamp + 6 }),
            winner: 1,
            claim1Timestamp: claims[6].timestamp,
            winnerTimestamp: timestamp + 6,
            actions: [],
            parentTournament: tournament,
        },
    ],
});
tournament.rounds.push({
    matches: [
        {
            claim1: tournament.rounds[0].matches[3].claim1,
            claim1Timestamp: tournament.rounds[0].matches[3]
                .winnerTimestamp as number,
            claim2: tournament.rounds[0].matches[2].claim1,
            claim2Timestamp: tournament.rounds[0].matches[2].claim1Timestamp,
            actions: [],
            parentTournament: tournament,
        },
        {
            claim1: tournament.rounds[0].matches[0].claim1,
            claim1Timestamp: tournament.rounds[0].matches[0].claim1Timestamp,
            actions: [],
            parentTournament: tournament,
        },
    ],
});

const mid: Tournament = {
    level: "MIDDLE",
    startCycle: startCycle / 1024n,
    endCycle: endCycle / 1024n,
    parentMatch: tournament.rounds[0].matches[1],
    rounds: [],
};
mid.rounds.push({
    matches: [
        {
            claim1: randomClaim(7, {
                timestamp: timestamp + 7,
                parentClaim: mid.parentMatch?.claim1,
            }),
            claim1Timestamp: timestamp + 7,
            claim2: randomClaim(8, {
                timestamp: timestamp + 8,
                parentClaim: mid.parentMatch?.claim2,
            }),
            claim2Timestamp: timestamp + 8,
            actions: [],
            parentTournament: mid,
        },
        {
            claim1: randomClaim(8, {
                timestamp: timestamp + 8,
                parentClaim: mid.parentMatch?.claim2,
            }),
            claim1Timestamp: timestamp + 8,
            claim2: randomClaim(9, {
                timestamp: timestamp + 9,
                parentClaim: mid.parentMatch?.claim1,
            }),
            claim2Timestamp: timestamp + 9,
            actions: [],
            parentTournament: mid,
        },
    ],
});

tournament.rounds[0].matches[1].tournament = mid;

export const Ongoing: Story = {
    args: {
        onClickMatch: fn(),
        tournament,
    },
};

export const NoChallengerYet: Story = {
    args: {
        onClickMatch: fn(),
        tournament: {
            level: "TOP",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            winner: undefined,
            rounds: [
                {
                    matches: [],
                },
            ],
        },
    },
};

export const Finalized: Story = {
    args: {
        onClickMatch: fn(),
        tournament: {
            level: "TOP",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            winner: claims[0],
            rounds: [
                {
                    matches: [],
                },
            ],
        },
    },
};

export const MidLevelDispute: Story = {
    args: {
        tournament: mid,
    },
};
