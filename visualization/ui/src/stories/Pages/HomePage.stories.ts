import type { Meta, StoryObj } from "@storybook/react-vite";
import Home from "../../view/home/Home";
import { applications } from "../data";

const meta = {
    title: "Pages/Home",
    component: Home,
} satisfies Meta<typeof Home>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: {
        applications,
    },
};
