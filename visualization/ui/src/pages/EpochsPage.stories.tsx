import { Stack } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { Hierarchy } from "../components/navigation/Hierarchy";
import { applications } from "../stories/data";
import { EpochsPage } from "./EpochsPage";

const meta = {
    title: "Pages/Epochs",
    component: EpochsPage,
    tags: ["autodocs"],
} satisfies Meta<typeof EpochsPage>;

export default meta;
type Story = StoryObj<typeof meta>;

type Props = Parameters<typeof EpochsPage>[0];

const WithBreadcrumb = (props: Props) => {
    const app = applications[0];
    return (
        <Stack gap="lg">
            <Hierarchy
                hierarchyConfig={[
                    { title: "Home", href: "/" },
                    { title: app.name, href: `/${app.name}` },
                ]}
            />
            <EpochsPage {...props} />
        </Stack>
    );
};

export const Default: Story = {
    render: WithBreadcrumb,
    args: {
        epochs: applications[0].epochs,
        appId: applications[0].name,
    },
};

export const NoDispute: Story = {
    render: WithBreadcrumb,
    args: {
        appId: applications[0].name,
        epochs: [
            applications[0].epochs[0],
            applications[0].epochs[1],
            applications[0].epochs[2],
            { ...applications[0].epochs[3], inDispute: false },
            applications[0].epochs[4],
        ],
    },
};
