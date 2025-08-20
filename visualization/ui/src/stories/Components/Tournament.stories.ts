import type { Meta, StoryObj } from "@storybook/react-vite";
import { fn } from "storybook/test";
import { keccak256, toBytes, zeroAddress } from "viem";
import { TournamentView } from "../../components/tournament/Tournament";
import type { Claim } from "../../components/types";
import { randomBisections } from "../util";

const meta = {
    title: "Components/Tournament",
    component: TournamentView,
} satisfies Meta<typeof TournamentView>;

export default meta;
type Story = StoryObj<typeof meta>;

const startTimestamp = Math.floor(Date.now() / 1000) * 1000;
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
}));

const startCycle = 1837880065n;
const endCycle = 2453987565n;

// create 4 bisections of the cycle range
const ranges = randomBisections([startCycle, endCycle], 4, 42);

export const Ongoing: Story = {
    args: {
        onClickMatch: fn(),
        tournament: {
            level: "TOP",
            startCycle,
            endCycle,
            rounds: [
                {
                    matches: [
                        {
                            claim1: claims[0],
                            claim2: claims[1],
                            winner: 1,
                            claim1Timestamp: claims[0].timestamp,
                            claim2Timestamp: claims[1].timestamp,
                            winnerTimestamp: claims[1].timestamp + 1000,
                            actions: [],
                        },
                        {
                            claim1: claims[2],
                            claim2: claims[3],
                            claim1Timestamp: claims[2].timestamp,
                            claim2Timestamp: claims[3].timestamp,
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
                        },
                        {
                            claim1: claims[4],
                            claim2: claims[5],
                            winner: 1,
                            claim1Timestamp: claims[4].timestamp,
                            claim2Timestamp: claims[5].timestamp,
                            winnerTimestamp: claims[5].timestamp + 1000,
                            actions: [],
                        },
                        {
                            claim1: claims[6],
                            winner: 1,
                            claim1Timestamp: claims[6].timestamp,
                            winnerTimestamp: claims[6].timestamp + 1000,
                            actions: [],
                        },
                    ],
                },
                {
                    matches: [
                        {
                            claim1: claims[6],
                            claim2: claims[4],
                            claim1Timestamp: claims[6].timestamp + 1000,
                            claim2Timestamp: claims[5].timestamp + 1000,
                            actions: [],
                        },
                        {
                            claim1: claims[0],
                            claim1Timestamp: claims[1].timestamp + 2000,
                            actions: [],
                        },
                    ],
                },
            ],
        },
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
                    matches: [
                        {
                            claim1: claims[0],
                            claim1Timestamp: claims[0].timestamp,
                            actions: [],
                        },
                    ],
                },
            ],
        },
    },
};

export const Closed: Story = {
    args: {
        onClickMatch: fn(),
        tournament: {
            level: "TOP",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            winner: claims[0],
            rounds: [
                {
                    matches: [
                        {
                            claim1: claims[0],
                            winner: 1,
                            claim1Timestamp: claims[0].timestamp,
                            winnerTimestamp: claims[0].timestamp + 1000,
                            actions: [],
                        },
                    ],
                },
            ],
        },
    },
};
