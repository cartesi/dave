import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { BisectionItem } from "../../components/match/BisectionItem";
import type { CycleRange } from "../../components/types";
import { claim } from "../util";

const meta = {
    title: "Components/Match/BisectionItem",
    component: BisectionItem,
    tags: ["autodocs"],
    decorators: [
        (Story) => (
            <Timeline bulletSize={24} lineWidth={2}>
                <Story />
            </Timeline>
        ),
    ],
} satisfies Meta<typeof BisectionItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);
const range = [1837880065, 2453987565] as CycleRange;
const [start, end] = range;

/**
 * Bisection in the middle of the range.
 */
export const Middle: Story = {
    args: {
        claim: claim(0),
        color: "gray.6",
        domain: range,
        index: 5,
        now,
        range: [(start + end) / 2, end],
        timestamp: now - 64,
        total: 48,
    },
};

/**
 * Bisection in the middle of the range.
 */
export const Quarter: Story = {
    args: {
        claim: claim(1),
        color: "gray.6",
        domain: [0, 100],
        index: 15,
        now,
        range: [25, 50],
        timestamp: now - 5398,
        total: 20,
    },
};

/**
 * Bisection in the middle of the range.
 */
export const Expand: Story = {
    args: {
        claim: claim(1),
        color: "gray.6",
        domain: [0, 100],
        expand: true,
        index: 15,
        now,
        range: [(100 / 16) * 3, (100 / 16) * 4],
        timestamp: now - 5398,
        total: 20,
    },
};
