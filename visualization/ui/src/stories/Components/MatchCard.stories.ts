import type { Meta, StoryObj } from "@storybook/react-vite";
import { fn } from "storybook/test";
import { keccak256, toBytes } from "viem";
import { MatchCard } from "../../components/tournament/MatchCard";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/Tournament/MatchCard",
    component: MatchCard,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof MatchCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const timestamp = Math.floor(Date.now() / 1000);
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
}));

/**
 * A match that is ongoing, which means that both claims are still in dispute, with no winner yet.
 */
export const Ongoing: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            timestamp,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match of a mid-level tournament, where claims have parent claims.
 */
export const MidLevel: Story = {
    args: {
        match: {
            claim1: { ...claims[0], parentClaim: claims[2] },
            claim2: { ...claims[1], parentClaim: claims[3] },
            timestamp,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match of a bottom-level tournament, where claims have parent claims.
 */
export const BottomLevel: Story = {
    args: {
        match: {
            claim1: {
                ...claims[0],
                parentClaim: { ...claims[2], parentClaim: claims[4] },
            },
            claim2: {
                ...claims[1],
                parentClaim: { ...claims[3], parentClaim: claims[5] },
            },
            timestamp,
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
            timestamp,
            winnerTimestamp: timestamp + 1,
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
            timestamp,
            winnerTimestamp: timestamp + 1,
            actions: [],
        },
        onClick: fn(),
    },
};

/**
 * A match that has a simulated time, when the match did not exist, so it must just not be shown.
 */
export const TimeTravel: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            timestamp,
            actions: [],
        },
        now: timestamp - 1,
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
            timestamp,
            winnerTimestamp: timestamp + 1,
            actions: [],
        },
        now: timestamp,
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
            timestamp,
            actions: [],
        },
    },
};
