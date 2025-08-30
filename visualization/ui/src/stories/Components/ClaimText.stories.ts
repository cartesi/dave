import type { Meta, StoryObj } from "@storybook/react-vite";
import { ClaimText } from "../../components/tournament/ClaimText";
import { claim } from "../util";

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

/**
 * The default display of a claim of a top tournament.
 */
export const Default: Story = {
    args: {
        claim: claim(0),
    },
};

/**
 * A mid level claim, which has a parent claim.
 */
export const MidLevelClaim: Story = {
    args: {
        claim: claim(1, 0),
    },
};

/**
 * A bottom level claim, which has two parent claims.
 */
export const BottomLevelClaim: Story = {
    args: {
        claim: claim(2, 1, 0),
    },
};

/**
 * Claim without icon.
 */
export const NoIcon: Story = {
    args: {
        claim: claim(0),
        withIcon: false,
    },
};
