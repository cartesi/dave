import type { Meta, StoryObj } from "@storybook/react-vite";
import { Honeypot } from "./Honeypot";

const meta = {
    title: "Pages/Honeypot",
    component: Honeypot,
} satisfies Meta<typeof Honeypot>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
