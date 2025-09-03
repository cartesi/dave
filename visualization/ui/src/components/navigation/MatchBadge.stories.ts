import type { Meta, StoryObj } from "@storybook/react-vite";
import { claim } from "../../stories/util";
import { MatchBadge } from "./MatchBadge";

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

/**
 * A badge with avatars for two claims.
 */
export const Default: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
    },
};

/**
 * A extra small badge with avatars for two claims.
 */
export const ExtraSmall: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "compact-xs",
    },
};

/**
 * A small badge with avatars for two claims.
 */
export const Small: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "compact-sm",
    },
};

/**
 * A medium badge with avatars for two claims.
 */
export const Medium: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "compact-md",
    },
};

/**
 * A large badge with avatars for two claims.
 */
export const Large: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "compact-lg",
    },
};

/**
 * A extra large badge with avatars for two claims.
 */
export const ExtraLarge: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "compact-xl",
    },
};
