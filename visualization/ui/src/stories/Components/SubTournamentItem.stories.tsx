import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { SubTournamentItem } from "../../components/match/SubTournamentItem";
import type { CycleRange } from "../../components/types";
import { claim } from "../util";

const meta = {
    title: "Components/Match/SubTournamentItem",
    component: SubTournamentItem,
    tags: ["autodocs"],
    decorators: [
        (Story) => (
            <Timeline bulletSize={24} lineWidth={2}>
                <Story />
            </Timeline>
        ),
    ],
} satisfies Meta<typeof SubTournamentItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);
const range = [1837880065, 2453987565] as CycleRange;

/**
 * Navigation to middle tournament.
 */
export const Middle: Story = {
    args: {
        claim: claim(0),
        level: "middle",
        now,
        range,
        timestamp: now,
    },
};

/**
 * Navigation to bottom tournament.
 */
export const Bottom: Story = {
    args: {
        claim: claim(0),
        level: "bottom",
        now,
        range,
        timestamp: now,
    },
};
