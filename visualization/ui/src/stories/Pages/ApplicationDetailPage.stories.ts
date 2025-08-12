import type { Meta, StoryObj } from "@storybook/react-vite";
import { HoneypotDapp } from "../../components/application/application.mocks";
import {
    closedEpoch,
    epochs,
    openEpoch,
    sealedEpoch,
} from "../../components/epoch/epoch.mocks";
import ApplicationView from "../../view/application/Application";

const meta = {
    title: "Pages/ApplicationView",
    component: ApplicationView,
} satisfies Meta<typeof ApplicationView>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
    args: {
        epochs: epochs,
        hierarchyConfig: [
            {
                title: "Home",
                href: "#",
            },
            {
                title: HoneypotDapp.address.toString(),
                href: "#",
            },
        ],
    },
};
export const HierarchyUsingApplicationName: Story = {
    args: {
        epochs: epochs,
        hierarchyConfig: [
            {
                title: "Home",
                href: "#",
            },
            {
                title: HoneypotDapp.name ?? HoneypotDapp.address,
                href: "#",
            },
        ],
    },
};

export const WithEpochInDispute: Story = {
    args: {
        epochs: [
            openEpoch,
            { ...sealedEpoch, inDispute: true },
            closedEpoch,
            { ...closedEpoch, index: 2 },
            { ...closedEpoch, index: 1 },
        ],
        hierarchyConfig: [
            {
                title: "Home",
                href: "#",
            },
            {
                title: HoneypotDapp.address,
                href: "#",
            },
        ],
    },
};
