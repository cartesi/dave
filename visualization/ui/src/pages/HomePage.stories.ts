import type { Meta, StoryObj } from "@storybook/react-vite";
import { applications } from "../stories/data";
import { HomePage } from "./HomePage";

const meta = {
    title: "Pages/Home",
    component: HomePage,
    tags: ["autodocs"],
} satisfies Meta<typeof HomePage>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: {
        applications,
    },
};
