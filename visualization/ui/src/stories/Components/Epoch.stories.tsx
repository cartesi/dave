import type { Meta, StoryObj } from "@storybook/react-vite";
import { EpochCard } from "../../components/epoch/Epoch";
import { epochs } from "../data";

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
    args: { epoch: epochs.honeypot[4] },
};

export const Closed: Story = {
    args: { epoch: { ...epochs.honeypot[3], inDispute: false } },
};

export const UnderDispute: Story = {
    args: { epoch: epochs.honeypot[3] },
};

export const Finalized: Story = {
    args: { epoch: epochs.honeypot[2] },
};
