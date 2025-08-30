import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchBadge } from "../../components/tournament/MatchBadge";
import { claim } from "../util";

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
        size: "xs",
    },
};

/**
 * A small badge with avatars for two claims.
 */
export const Small: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "sm",
    },
};

/**
 * A medium badge with avatars for two claims.
 */
export const Medium: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "md",
    },
};

/**
 * A large badge with avatars for two claims.
 */
export const Large: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "lg",
    },
};

/**
 * A extra large badge with avatars for two claims.
 */
export const ExtraLarge: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        size: "xl",
    },
};
