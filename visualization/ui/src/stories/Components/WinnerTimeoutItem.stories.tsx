import { Timeline } from "@mantine/core";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { WinnerTimeoutItem } from "../../components/match/WinnerTimeoutItem";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/WinnerTimeoutItem",
    component: WinnerTimeoutItem,
    tags: ["autodocs"],
    decorators: [
        (Story) => (
            <Timeline bulletSize={24} lineWidth={2}>
                <Story />
            </Timeline>
        ),
    ],
} satisfies Meta<typeof WinnerTimeoutItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);

const randomClaim = (i: number, c?: Pick<Claim, "parentClaim">): Claim => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    parentClaim: c?.parentClaim,
});

/**
 * Winner is first claim
 */
export const Default: Story = {
    args: {
        winner: randomClaim(0),
        loser: randomClaim(1),
        timestamp: now,
    },
};
