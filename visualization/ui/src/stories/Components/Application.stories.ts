import type { Meta, StoryObj } from "@storybook/react-vite";
import { ApplicationCard } from "../../components/application/Application";
import { applications } from "../data";

const meta = {
    title: "Components/Application",
    component: ApplicationCard,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof ApplicationCard>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: { application: applications[0] },
};

export const Disabled: Story = {
    args: { application: { ...applications[0], state: "DISABLED" } },
};

export const Inoperable: Story = {
    args: { application: { ...applications[0], state: "INOPERABLE" } },
};

export const NoInputs: Story = {
    args: { application: { ...applications[0], processedInputs: 0 } },
};

export const AuthorityConsensus: Story = {
    args: { application: { ...applications[0], consensusType: "AUTHORITY" } },
};
