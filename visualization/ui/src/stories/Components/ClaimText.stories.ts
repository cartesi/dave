import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes } from "viem";
import { ClaimText } from "../../components/tournament/ClaimText";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/General/ClaimText",
    component: ClaimText,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof ClaimText>;

export default meta;
type Story = StoryObj<typeof meta>;

const startTimestamp = Date.now();
const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
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

/**
 * Claim without icon.
 */
export const NoIcon: Story = {
    args: {
        claim: claims[0],
        withIcon: false,
    },
};
