import type { Meta, StoryObj } from "@storybook/react-vite";
import { applications } from "../../stories/data";
import { EpochCard } from "./EpochCard";

const meta = {
    title: "Components/Epoch/EpochCard",
    component: EpochCard,
    tags: ["autodocs"],
} satisfies Meta<typeof EpochCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const epoch = {
    ...applications[0].epochs[3],
    tournament: undefined,
};

/**
 * Card for an open epoch
 */
export const Open: Story = {
    args: { epoch: applications[0].epochs[4] },
};

/**
 * Card for a closed epoch
 */
export const Closed: Story = {
    args: { epoch: { ...epoch, inDispute: false } },
};

/**
 * Card for an epoch that is under dispute
 */
export const UnderDispute: Story = {
    args: { epoch: epoch },
};

/**
 * Card for a finalized epoch
 */
export const Finalized: Story = {
    args: { epoch: applications[0].epochs[2] },
};
