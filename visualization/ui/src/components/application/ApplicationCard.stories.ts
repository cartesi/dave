import type { Meta, StoryObj } from "@storybook/react-vite";
import { applications } from "../../stories/data";
import { ApplicationCard } from "./ApplicationCard";

const meta = {
    title: "Components/Application/ApplicationCard",
    component: ApplicationCard,
    tags: ["autodocs"],
} satisfies Meta<typeof ApplicationCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const honeypot = {
    ...applications[0],
    epochs: [],
};

/**
 * Default application card
 */
export const Default: Story = {
    args: { application: honeypot },
};

/**
 * Card for a disabled application
 */
export const Disabled: Story = {
    args: { application: { ...honeypot, state: "DISABLED" } },
};

/**
 * Card for application that is inoperable
 */
export const Inoperable: Story = {
    args: { application: { ...honeypot, state: "INOPERABLE" } },
};

/**
 * Card for applications with no inputs
 */
export const NoInputs: Story = {
    args: { application: { ...honeypot, processedInputs: 0 } },
};

/**
 * Card for applications that use an Authority consensus
 */
export const AuthorityConsensus: Story = {
    args: { application: { ...honeypot, consensusType: "AUTHORITY" } },
};
