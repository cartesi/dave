import { Stack } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { Hierarchy } from "../components/navigation/Hierarchy";
import { applications } from "../stories/data";
import { EpochDetailsPage } from "./EpochDetailsPage";

const meta = {
    title: "Pages/Epoch Details",
    component: EpochDetailsPage,
    tags: ["autodocs"],
} satisfies Meta<typeof EpochDetailsPage>;

export default meta;
type Story = StoryObj<typeof meta>;

type Props = Parameters<typeof EpochDetailsPage>[0];

const WithBreadcrumb = (props: Props) => {
    const app = applications[0];
    return (
        <Stack gap="lg">
            <Hierarchy
                hierarchyConfig={[
                    { title: "Home", href: "/" },
                    { title: app.name, href: `/${app.name}` },
                    { title: `Epoch #${props.epoch.index}`, href: "#" },
                ]}
            />
            <EpochDetailsPage {...props} />
        </Stack>
    );
};

export const Open: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: applications[0].epochs[4].tournament,
        epoch: applications[0].epochs[4],
        inputs: [
            {
                index: 2,
                status: "ACCEPTED",
                epochIndex: 0,
                machineHash:
                    "0xd721e60f83c8fc277b2d2e23a24e77a4035ee1f482b64486a78dd5598f11364b",
                outputHash:
                    "0x0a162946e56158bac0673e6dd3bdfdc1e4a0e7744a120fdb640050c8d7abe1c6",
                payload:
                    "0x7b22616374696f6e223a226a616d2e7365744e465441646472657373222c2261646472657373223a22307865376631373235453737333443453238384638333637653142623134334539306262334630353132227d",
                sender: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            },
            {
                index: 1,
                status: "NONE",
                epochIndex: 0,
                machineHash:
                    "0xd721e60f83c8fc277b2d2e23a24e77a4035ee1f482b64486a78dd5598f11364b",
                outputHash:
                    "0xabbc4c1594a60078ddfc55bb7c96f1b5f4b3b67302c336cc98dc327fbe05e637",
                payload:
                    "0x7b22616374696f6e223a226a616d2e7365744e465441646472657373222c2261646472657373223a22307865376631373235453737333443453238384638333637653142623134334539306262334630353132227d",
                sender: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            },
            {
                index: 0,
                status: "REJECTED",
                epochIndex: 0,
                machineHash:
                    "0xd721e60f83c8fc277b2d2e23a24e77a4035ee1f482b64486a78dd5598f11364b",
                outputHash:
                    "0x4eae49a33bf0456bfdcc9653b2b422b831acb318dc2e38b7d12a5af66a14ae78",
                payload:
                    "0x7b22616374696f6e223a226a616d2e7365744e465441646472657373222c2261646472657373223a22307865376631373235453737333443453238384638333637653142623134334539306262334630353132227d",
                sender: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            },
        ],
    },
};

export const ClosedInDispute: Story = {
    render: WithBreadcrumb,
    args: {
        tournament: applications[0].epochs[3].tournament,
        epoch: applications[0].epochs[3],
        inputs: [
            {
                index: 2,
                status: "ACCEPTED",
                epochIndex: 0,
                machineHash:
                    "0xd721e60f83c8fc277b2d2e23a24e77a4035ee1f482b64486a78dd5598f11364b",
                outputHash:
                    "0x0a162946e56158bac0673e6dd3bdfdc1e4a0e7744a120fdb640050c8d7abe1c6",
                payload:
                    "0x7b22616374696f6e223a226a616d2e7365744e465441646472657373222c2261646472657373223a22307865376631373235453737333443453238384638333637653142623134334539306262334630353132227d",
                sender: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            },
            {
                index: 1,
                status: "NONE",
                epochIndex: 0,
                machineHash:
                    "0xd721e60f83c8fc277b2d2e23a24e77a4035ee1f482b64486a78dd5598f11364b",
                outputHash:
                    "0xabbc4c1594a60078ddfc55bb7c96f1b5f4b3b67302c336cc98dc327fbe05e637",
                payload:
                    "0x7b22616374696f6e223a226a616d2e7365744e465441646472657373222c2261646472657373223a22307865376631373235453737333443453238384638333637653142623134334539306262334630353132227d",
                sender: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            },
            {
                index: 0,
                status: "REJECTED",
                epochIndex: 0,
                machineHash:
                    "0xd721e60f83c8fc277b2d2e23a24e77a4035ee1f482b64486a78dd5598f11364b",
                outputHash:
                    "0x4eae49a33bf0456bfdcc9653b2b422b831acb318dc2e38b7d12a5af66a14ae78",
                payload:
                    "0x7b22616374696f6e223a226a616d2e7365744e465441646472657373222c2261646472657373223a22307865376631373235453737333443453238384638333637653142623134334539306262334630353132227d",
                sender: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            },
        ],
    },
};
