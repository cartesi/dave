import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes } from "viem";
import { claim } from "../../stories/util";
import { Dispute } from "./Dispute";

const meta = {
    title: "Components/Honeypot/Dispute",
    component: Dispute,
    tags: ["autodocs"],
} satisfies Meta<typeof Dispute>;

export default meta;
type Story = StoryObj<typeof meta>;

const claims = Array.from({ length: 32 }).map((_, i) => claim(i));

/**
 * A dispute between two claims.
 */
export const TwoClaims: Story = {
    args: {
        claims: claims.slice(0, 2).map((claim) => claim.hash),
        eliminatedClaims: [],
    },
};

/**
 * A dispute with 5 claims, where 2 are eliminated
 */
export const FiveClaims: Story = {
    args: {
        claims: claims.slice(0, 3).map((claim) => claim.hash),
        eliminatedClaims: claims.slice(3, 5).map((claim) => claim.hash),
    },
};

/**
 * A dispute with 5 claims, where 2 are eliminated
 */
export const Winner: Story = {
    args: {
        claims: [],
        eliminatedClaims: claims.slice(1, 5).map((claim) => claim.hash),
        winner: claims[0].hash,
    },
};

/**
 * A dispute with 5 claims, where 2 are eliminated
 */
export const SybilAttack: Story = {
    args: {
        claims: Array.from({ length: 200 }).map((_, i) =>
            keccak256(toBytes(i)),
        ),
        eliminatedClaims: [],
    },
};
