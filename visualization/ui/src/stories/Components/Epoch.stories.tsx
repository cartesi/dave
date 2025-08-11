import type { Meta, StoryObj } from "@storybook/react-vite";
import { EpochCard } from "../../components/epoch/Epoch";
import {
    closedEpoch,
    openEpoch,
    sealedEpoch,
} from "../../components/epoch/epoch.mocks";

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
    args: { epoch: openEpoch },
};

export const Sealed: Story = {
    args: { epoch: sealedEpoch },
};

export const SealedUnderDispute: Story = {
    args: { epoch: { ...sealedEpoch, inDispute: true } },
};

export const ClosedEpoch: Story = {
    args: { epoch: closedEpoch },
};
