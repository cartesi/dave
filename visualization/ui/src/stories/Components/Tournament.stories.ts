import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { TournamentView } from "../../components/tournament/Tournament";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/Tournament",
    component: TournamentView,
} satisfies Meta<typeof TournamentView>;

export default meta;
type Story = StoryObj<typeof meta>;

const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: Date.now(),
}));

export const Ongoing: Story = {
    args: {
        tournament: {
            level: "top",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            rounds: [
                {
                    matches: [
                        {
                            claim1: claims[0],
                            claim2: claims[1],
                            winner: 1,
                        },
                        {
                            claim1: claims[2],
                            claim2: claims[3],
                        },
                        {
                            claim1: claims[4],
                            claim2: claims[5],
                            winner: 1,
                        },
                        {
                            claim1: claims[6],
                            winner: 1,
                        },
                    ],
                },
                {
                    matches: [
                        {
                            claim1: claims[6],
                            claim2: claims[4],
                        },
                        {
                            claim1: claims[0],
                        },
                    ],
                },
            ],
        },
    },
};

export const NoChallengerYet: Story = {
    args: {
        tournament: {
            level: "top",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            winner: undefined,
            rounds: [
                {
                    matches: [{ claim1: claims[0] }],
                },
            ],
        },
    },
};

export const Closed: Story = {
    args: {
        tournament: {
            level: "top",
            startCycle: 1837880065n,
            endCycle: 2453987565n,
            winner: claims[0],
            rounds: [
                {
                    matches: [{ claim1: claims[0], winner: 1 }],
                },
            ],
        },
    },
};
