import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { BisectionProgress } from "../../components/match/BisectionProgress";
import type { Claim } from "../../components/types";
import { mulberry32 } from "../util";

const meta = {
    title: "Components/BisectionProgress",
    component: BisectionProgress,
} satisfies Meta<typeof BisectionProgress>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);
const start = 14_837_880_065;
const end = 21_453_987_565;

const rng = mulberry32(0);

const randomClaim = (i: number, c?: Pick<Claim, "parentClaim">): Claim => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    parentClaim: c?.parentClaim,
});

export const Ongoing: Story = {
    args: {
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        range: [start, end],
        bisections: [
            { direction: 0, timestamp: now - 3402 },
            { direction: 1, timestamp: now - 1548 },
            { direction: 1, timestamp: now - 763 },
            { direction: 0, timestamp: now - 354 },
        ],
        max: 48,
    },
};

/**
 * A progress with no bisections yet
 */
export const NoBisections: Story = {
    args: {
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        range: [start, end],
        bisections: [],
        max: 48,
    },
};

/**
 * Complete large bisection
 */
export const ManyBisections: Story = {
    args: {
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        range: [start, end],
        bisections: Array.from({ length: 20 }, (_, i) => ({
            direction: rng() < 0.5 ? 0 : 1,
            timestamp: now - 3600 + i * 60,
        })),
        max: 48,
    },
};

/**
 * Complete large bisection
 */
export const Complete: Story = {
    args: {
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        range: [start, end],
        bisections: Array.from({ length: 48 }, (_, i) => ({
            direction: rng() < 0.5 ? 0 : 1,
            timestamp: now - 3600 + i * 60,
        })),
        max: 48,
    },
};
