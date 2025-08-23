import type { Meta, StoryObj } from "@storybook/react-vite";
import { ApplicationCard } from "../../components/application/Application";
import { applications } from "../data";

const meta = {
    title: "Components/Application",
    component: ApplicationCard,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof ApplicationCard>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Default application card
 */
export const Default: Story = {
    args: { application: applications[0] },
};

/**
 * Card for a disabled application
 */
export const Disabled: Story = {
    args: { application: { ...applications[0], state: "DISABLED" } },
};

/**
 * Card for application that is inoperable
 */
export const Inoperable: Story = {
    args: { application: { ...applications[0], state: "INOPERABLE" } },
};

/**
 * Card for applications with no inputs
 */
export const NoInputs: Story = {
    args: { application: { ...applications[0], processedInputs: 0 } },
};

/**
 * Card for applications that use an Authority consensus
 */
export const AuthorityConsensus: Story = {
    args: { application: { ...applications[0], consensusType: "AUTHORITY" } },
};
