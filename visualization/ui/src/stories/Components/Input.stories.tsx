import type { Meta, StoryObj } from "@storybook/react-vite";
import { InputCard } from "../../components/input/Input";
import {
    acceptedInput,
    noneInput,
    rejectedInput,
} from "../../components/input/input.mocks";

const meta = {
    title: "Components/Input",
    component: InputCard,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof InputCard>;

export default meta;
type Story = StoryObj<typeof meta>;

export const AcceptedStatus: Story = {
    args: { input: acceptedInput },
};

export const NoneStatus: Story = {
    args: { input: noneInput },
};

export const RejectedStatus: Story = {
    args: { input: rejectedInput },
};
