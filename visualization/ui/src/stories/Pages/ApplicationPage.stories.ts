import type { Meta, StoryObj } from "@storybook/react-vite";
import ApplicationView from "../../view/application/Application";
import { applications, epochs } from "../data";

const meta = {
    title: "Pages/Application",
    component: ApplicationView,
} satisfies Meta<typeof ApplicationView>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: {
        application: applications[0],
        epochs: epochs.honeypot,
    },
};

export const NoDispute: Story = {
    args: {
        application: applications[0],
        epochs: [
            epochs.honeypot[0],
            epochs.honeypot[1],
            epochs.honeypot[2],
            { ...epochs.honeypot[3], inDispute: false },
            epochs.honeypot[4],
        ],
    },
};
