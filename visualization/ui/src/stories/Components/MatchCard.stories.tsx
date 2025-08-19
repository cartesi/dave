import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { MatchCard } from "../../components/tournament/MatchCard";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/MatchCard",
    component: MatchCard,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof MatchCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const startTimestamp = Date.now();
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
}));

export const Ongoing: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
        },
    },
};

export const Winner1: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 1,
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            winnerTimestamp: claims[1].timestamp + 1000,
        },
    },
};

export const Winner2: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 2,
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            winnerTimestamp: claims[1].timestamp + 1000,
        },
    },
};

export const Waiting: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim1Timestamp: claims[0].timestamp,
        },
    },
};

export const OneClaim: Story = {
    args: {
        match: {
            claim1: claims[0],
            winner: 1,
            claim1Timestamp: claims[0].timestamp,
            winnerTimestamp: claims[0].timestamp + 1000,
        },
    },
};

export const TimeTravelBothClaims: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
        },
        now: Math.min(claims[0].timestamp, claims[1].timestamp) - 1000,
    },
};

export const TimeTravelOneClaim: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
        },
        now: Math.max(claims[0].timestamp, claims[1].timestamp) - 1000,
    },
};

export const TimeTravelWinner: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 1,
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            winnerTimestamp: claims[1].timestamp + 1000,
        },
        now: Math.max(claims[0].timestamp, claims[1].timestamp),
    },
};
