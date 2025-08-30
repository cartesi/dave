import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes } from "viem";
import { BisectionItem } from "../../components/match/BisectionItem";
import type { Claim, CycleRange } from "../../components/types";

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

const randomClaim = (i: number, c?: Pick<Claim, "parentClaim">): Claim => ({
    hash: keccak256(toBytes(i)),
    parentClaim: c?.parentClaim,
});

/**
 * Bisection in the middle of the range.
 */
export const Middle: Story = {
    args: {
        claim: randomClaim(0),
        domain: range,
        range: [(start + end) / 2, end],
        index: 5,
        timestamp: now - 64,
        total: 48,
    },
};

/**
 * Bisection in the middle of the range.
 */
export const Quarter: Story = {
    args: {
        claim: randomClaim(1),
        domain: [0, 100],
        range: [25, 50],
        index: 15,
        timestamp: now - 5398,
        total: 20,
    },
};
