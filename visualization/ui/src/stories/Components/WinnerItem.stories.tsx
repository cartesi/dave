import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { type Hex } from "viem";
import { WinnerItem } from "../../components/match/WinnerItem";
import { claim } from "../util";

const meta = {
    title: "Components/Match/WinnerItem",
    component: WinnerItem,
    tags: ["autodocs"],
    decorators: [
        (Story) => (
            <Timeline bulletSize={24} lineWidth={2}>
                <Story />
            </Timeline>
        ),
    ],
} satisfies Meta<typeof WinnerItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);

// large 40kb proof
const proof = `0x${"00".repeat(1024 * 40)}` as Hex;

/**
 * Default scenario
 */
export const Default: Story = {
    args: {
        claim: claim(0),
        now,
        proof,
        timestamp: now - 3452,
    },
};

/**
 * Small proof size
 */
export const SmallProof: Story = {
    args: {
        claim: claim(0),
        now,
        proof: `0x${"00".repeat(128)}` as Hex,
        timestamp: now - 3452,
    },
};
