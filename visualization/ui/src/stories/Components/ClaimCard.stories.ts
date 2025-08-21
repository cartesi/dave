import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { ClaimCard } from "../../components/tournament/ClaimCard";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/ClaimCard",
    component: ClaimCard,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof ClaimCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const startTimestamp = Date.now();
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
}));

/**
 * The default display of a claim of a top tournament.
 */
export const Default: Story = {
    args: {
        claim: claims[0],
    },
};

/**
 * A mid level claim, which has a parent claim.
 */
export const MidLevelClaim: Story = {
    args: {
        claim: { ...claims[1], parentClaim: claims[0] },
    },
};

/**
 * A bottom level claim, which has two parent claims.
 */
export const BottomLevelClaim: Story = {
    args: {
        claim: {
            ...claims[2],
            parentClaim: { ...claims[1], parentClaim: claims[0] },
        },
    },
};
