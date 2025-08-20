import type { Meta, StoryObj } from "@storybook/react-vite";
import { fn } from "storybook/test";
import { keccak256, toBytes, zeroAddress } from "viem";
import { MatchCard } from "../../components/tournament/MatchCard";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/MatchCard",
    component: MatchCard,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof MatchCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const startTimestamp = Date.now();
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
}));

/**
 * A match that is ongoing, which means that both claims are still in dispute, with no winner yet.
 */
export const Ongoing: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match that the first claim is the winner.
 */
export const Winner1: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 1,
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            winnerTimestamp: claims[1].timestamp + 1000,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match that the second claim is the winner.
 */
export const Winner2: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 2,
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            winnerTimestamp: claims[1].timestamp + 1000,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match that is waiting to be paired with another claim from a previous round.
 */
export const Waiting: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim1Timestamp: claims[0].timestamp,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match that is not matched with another claim, and was automatically declared as a winner.
 */
export const OneClaim: Story = {
    args: {
        match: {
            claim1: claims[0],
            winner: 1,
            claim1Timestamp: claims[0].timestamp,
            winnerTimestamp: claims[0].timestamp + 1000,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match that has a simulated time, when none of the claims were participants yet, so it must just not be shown.
 */
export const TimeTravelBothClaims: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            actions: [],
        },
        now: Math.min(claims[0].timestamp, claims[1].timestamp) - 1000,
        onClick: fn(),
    },
};

/**
 * A match that has a simulated time, when only one of the claims were part of the match.
 */
export const TimeTravelOneClaim: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            actions: [],
        },
        now: Math.max(claims[0].timestamp, claims[1].timestamp) - 1000,
        onClick: fn(),
    },
};

/**
 * A match that has a simulated time, when the winner was not declared yet.
 */
export const TimeTravelWinner: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 1,
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            winnerTimestamp: claims[1].timestamp + 1000,
            actions: [],
        },
        now: Math.max(claims[0].timestamp, claims[1].timestamp),
        onClick: fn(),
    },
};

/**
 * A match without a onClick event handler, which should change the cursor feedback.
 */
export const NoClickEventHandler: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            claim1Timestamp: claims[0].timestamp,
            claim2Timestamp: claims[1].timestamp,
            actions: [],
        },
    },
};
