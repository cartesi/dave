import type { Meta, StoryObj } from "@storybook/react-vite";
import ApplicationView from "../../view/application/Application";
import { applications } from "../data";

const meta = {
    title: "Pages/Application",
    component: ApplicationView,
    tags: ["autodocs"],
} satisfies Meta<typeof ApplicationView>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: {
        application: applications[0],
        epochs: applications[0].epochs,
    },
};

export const NoDispute: Story = {
    args: {
        application: applications[0],
        epochs: [
            applications[0].epochs[0],
            applications[0].epochs[1],
            applications[0].epochs[2],
            { ...applications[0].epochs[3], inDispute: false },
            applications[0].epochs[4],
        ],
    },
};
