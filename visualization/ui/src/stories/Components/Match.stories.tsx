import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { MatchCard } from "../../components/tournament/Match";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/Match",
    component: MatchCard,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof MatchCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: Date.now(),
}));

export const Ongoing: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
    },
};

export const Winner1: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 1,
        },
    },
};

export const Winner2: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
            winner: 2,
        },
    },
};

export const Waiting: Story = {
    args: {
        match: {
            claim1: claims[0],
        },
    },
};

export const OneClaim: Story = {
    args: {
        match: {
            claim1: claims[0],
            winner: 1,
        },
    },
};
