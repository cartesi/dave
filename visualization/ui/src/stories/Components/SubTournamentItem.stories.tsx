import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { SubTournamentItem } from "../../components/match/SubTournamentItem";
import type { Claim, CycleRange } from "../../components/types";

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

const randomClaim = (i: number, c?: Pick<Claim, "parentClaim">): Claim => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    parentClaim: c?.parentClaim,
});

const now = Math.floor(Date.now() / 1000);
const range = [1837880065, 2453987565] as CycleRange;

/**
 * Navigation to middle tournament.
 */
export const Middle: Story = {
    args: {
        claim: randomClaim(0),
        level: "middle",
        range,
        timestamp: now,
    },
};

/**
 * Navigation to bottom tournament.
 */
export const Bottom: Story = {
    args: {
        claim: randomClaim(0),
        level: "bottom",
        range,
        timestamp: now,
    },
};
