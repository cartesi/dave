import type { Meta, StoryObj } from "@storybook/react-vite";
import { InputCard } from "../../components/input/Input";
import * as EpochPageStories from "../Pages/EpochPage.stories";

const meta = {
    title: "Components/Input/Input",
    component: InputCard,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof InputCard>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Card for an accepted input
 */
export const AcceptedStatus: Story = {
    args: { input: EpochPageStories.Open.args.inputs[0] },
};

/**
 * Card for a non-processed input
 */
export const NoneStatus: Story = {
    args: { input: EpochPageStories.Open.args.inputs[1] },
};

/**
 * Card for a rejected input
 */
export const RejectedStatus: Story = {
    args: { input: EpochPageStories.Open.args.inputs[2] },
};
