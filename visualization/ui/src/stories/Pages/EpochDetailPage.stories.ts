import type { Meta, StoryObj } from "@storybook/react-vite";
import { HoneypotDapp } from "../../components/application/application.mocks";
import { openEpoch } from "../../components/epoch/epoch.mocks";
import { inputs } from "../../components/input/input.mocks";
import EpochView from "../../view/epoch/Epoch";

const meta = {
    title: "Pages/EpochView",
    component: EpochView,
} satisfies Meta<typeof EpochView>;

export default meta;
type Story = StoryObj<typeof meta>;

export const OpenEpoch: Story = {
    args: {
        epoch: openEpoch,
        inputs: inputs,
        hierarchyConfig: [
            {
                title: "Home",
                href: "#",
            },
            {
                title: HoneypotDapp.name.toString(),
                href: "#",
            },
            {
                title: `Epoch ${openEpoch.index}`,
                href: "#",
            },
        ],
    },
};
