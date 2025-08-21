import type { Meta, StoryObj } from "@storybook/react-vite";
import { EpochCard } from "../../components/epoch/Epoch";
import { applications } from "../data";

const meta = {
    title: "Components/Epoch",
    component: EpochCard,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof EpochCard>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Open: Story = {
    args: { epoch: applications[0].epochs[4] },
};

export const Closed: Story = {
    args: { epoch: { ...applications[0].epochs[3], inDispute: false } },
};

export const UnderDispute: Story = {
    args: { epoch: applications[0].epochs[3] },
};

export const Finalized: Story = {
    args: { epoch: applications[0].epochs[2] },
};
