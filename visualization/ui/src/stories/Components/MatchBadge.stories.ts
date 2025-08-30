import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes } from "viem";
import { MatchBadge } from "../../components/tournament/MatchBadge";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/Navigation/MatchBadge",
    component: MatchBadge,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof MatchBadge>;

export default meta;
type Story = StoryObj<typeof meta>;

const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
}));

/**
 * A badge with avatars for two claims.
 */
export const Default: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
    },
};

/**
 * A extra small badge with avatars for two claims.
 */
export const ExtraSmall: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
        size: "xs",
    },
};

/**
 * A small badge with avatars for two claims.
 */
export const Small: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
        size: "sm",
    },
};

/**
 * A medium badge with avatars for two claims.
 */
export const Medium: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
        size: "md",
    },
};

/**
 * A large badge with avatars for two claims.
 */
export const Large: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
        size: "lg",
    },
};

/**
 * A extra large badge with avatars for two claims.
 */
export const ExtraLarge: Story = {
    args: {
        match: {
            claim1: claims[0],
            claim2: claims[1],
        },
        size: "xl",
    },
};
