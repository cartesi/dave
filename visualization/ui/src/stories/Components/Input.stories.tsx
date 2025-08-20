import type { Meta, StoryObj } from "@storybook/react-vite";
import { InputCard } from "../../components/input/Input";
import * as EpochPageStories from "../Pages/EpochPage.stories";

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
    args: { input: EpochPageStories.OpenEpoch.args.inputs[0] },
};

export const NoneStatus: Story = {
    args: { input: EpochPageStories.OpenEpoch.args.inputs[1] },
};

export const RejectedStatus: Story = {
    args: { input: EpochPageStories.OpenEpoch.args.inputs[2] },
};
