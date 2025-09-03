import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { claim } from "../../stories/util";
import { LoserItem } from "./LoserItem";

const meta = {
    title: "Components/Match/LoserItem",
    component: LoserItem,
    tags: ["autodocs"],
    decorators: [
        (Story) => (
            <Timeline bulletSize={24} lineWidth={2}>
                <Story />
            </Timeline>
        ),
    ],
} satisfies Meta<typeof LoserItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);

/**
 * Winner is first claim
 */
export const Default: Story = {
    args: {
        claim: claim(0),
        now,
    },
};
