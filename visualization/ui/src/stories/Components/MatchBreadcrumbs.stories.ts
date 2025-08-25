import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { MatchBreadcrumbs } from "../../components/MatchBreadcrumbs";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/MatchBreadcrumbs",
    component: MatchBreadcrumbs,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof MatchBreadcrumbs>;

export default meta;
type Story = StoryObj<typeof meta>;

const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
}));

/**
 * Breadcrumbs for a bottom match.
 */
export const BottomMatch: Story = {
    args: {
        match: {
            actions: [],
            claim1: claims[0],
            claim2: claims[1],
            parentTournament: {
                level: "BOTTOM",
                startCycle: 5,
                endCycle: 6,
                matches: [],
                parentMatch: {
                    claim1: claims[2],
                    claim2: claims[3],
                    parentTournament: {
                        level: "MIDDLE",
                        startCycle: 10,
                        endCycle: 20,
                        matches: [],
                        parentMatch: {
                            claim1: claims[4],
                            claim2: claims[5],
                            parentTournament: {
                                level: "TOP",
                                startCycle: 1,
                                endCycle: 100,
                                matches: [],
                            },
                            actions: [],
                            timestamp: 1,
                        },
                    },
                    actions: [],
                    timestamp: 1,
                },
            },
            timestamp: 1,
        },
    },
};

/**
 * Breadcrumbs for a middle match.
 */
export const MidMatch: Story = {
    args: {
        match: {
            actions: [],
            claim1: claims[2],
            claim2: claims[3],
            timestamp: 1,
            parentTournament: {
                level: "MIDDLE",
                startCycle: 10,
                endCycle: 20,
                matches: [],
                parentMatch: {
                    claim1: claims[4],
                    claim2: claims[5],
                    parentTournament: {
                        level: "TOP",
                        startCycle: 1,
                        endCycle: 100,
                        matches: [],
                    },
                    actions: [],
                    timestamp: 1,
                },
            },
        },
    },
};

/**
 * Breadcrumbs for a top match.
 */
export const TopMatch: Story = {
    args: {
        match: {
            actions: [],
            claim1: claims[4],
            claim2: claims[5],
            parentTournament: {
                level: "TOP",
                startCycle: 1,
                endCycle: 100,
                matches: [],
            },
            timestamp: 1,
        },
    },
};
