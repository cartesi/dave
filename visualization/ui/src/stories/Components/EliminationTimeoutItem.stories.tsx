import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { EliminationTimeoutItem } from "../../components/match/EliminationTimeoutItem";
import { claim } from "../util";

const meta = {
    title: "Components/Match/EliminationTimeoutItem",
    component: EliminationTimeoutItem,
    tags: ["autodocs"],
    decorators: [
        (Story) => (
            <Timeline bulletSize={24} lineWidth={2}>
                <Story />
            </Timeline>
        ),
    ],
} satisfies Meta<typeof EliminationTimeoutItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);

/**
 * Winner is first claim
 */
export const Default: Story = {
    args: {
        claim1: claim(0),
        claim2: claim(1),
        now,
        timestamp: now - 3452,
    },
};
