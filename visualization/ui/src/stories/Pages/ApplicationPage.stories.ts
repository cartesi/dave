import type { Meta, StoryObj } from "@storybook/react-vite";
import Home from "../../view/home/Home";

const meta = {
    title: "Pages/Home",
    component: Home,
    parameters: {
        // @example Optional parameter to center the component in the Canvas. More info: https://storybook.js.org/docs/configure/story-layout
        // layout: "centered",
    },
} satisfies Meta<typeof Home>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: {},
};
