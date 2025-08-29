import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { Dispute } from "../../components/honeypot/Dispute";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/Honeypot/Dispute",
    component: Dispute,
    tags: ["autodocs"],
} satisfies Meta<typeof Dispute>;

export default meta;
type Story = StoryObj<typeof meta>;

const startTimestamp = Date.now();
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
}));

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
export const SybilAttack: Story = {
    args: {
        claims: Array.from({ length: 200 }).map((_, i) =>
            keccak256(toBytes(i)),
        ),
        eliminatedClaims: [],
    },
};
