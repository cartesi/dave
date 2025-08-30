import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
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

/**
 * Winner is first claim
 */
export const Default: Story = {
    args: {
        winner: claim(0),
        loser: claim(1),
        timestamp: now,
    },
};
