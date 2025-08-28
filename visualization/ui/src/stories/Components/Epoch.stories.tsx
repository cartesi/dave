import type { Meta, StoryObj } from "@storybook/react-vite";
import { EpochCard } from "../../components/epoch/Epoch";
import { applications } from "../data";

const meta = {
    title: "Components/Epoch/Epoch",
    component: EpochCard,
    tags: ["autodocs"],
} satisfies Meta<typeof EpochCard>;

export default meta;
type Story = StoryObj<typeof meta>;

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
    args: { epoch: { ...applications[0].epochs[3], inDispute: false } },
};

/**
 * Card for an epoch that is under dispute
 */
export const UnderDispute: Story = {
    args: { epoch: applications[0].epochs[3] },
};

/**
 * Card for a finalized epoch
 */
export const Finalized: Story = {
    args: { epoch: applications[0].epochs[2] },
};
