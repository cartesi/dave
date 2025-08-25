import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import { TournamentBreadcrumbs } from "../../components/TournamentBreadcrumbs";
import type { Claim } from "../../components/types";

const meta = {
    title: "Components/TournamentBreadcrumbs",
    component: TournamentBreadcrumbs,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof TournamentBreadcrumbs>;

export default meta;
type Story = StoryObj<typeof meta>;

const claims: Claim[] = Array.from({ length: 32 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
}));

/**
 * Breadcrumbs for a bottom tournament.
 */
export const BottomTournament: Story = {
    args: {
        tournament: {
            level: "BOTTOM",
            parentMatch: {
                claim1: claims[0],
                claim2: claims[1],
                parentTournament: {
                    level: "MIDDLE",
                    startCycle: 10,
                    endCycle: 20,
                    matches: [],
                    parentMatch: {
                        claim1: claims[2],
                        claim2: claims[3],
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
    },
};

/**
 * Breadcrumbs for a middle tournament.
 */
export const MidTournament: Story = {
    args: {
        tournament: {
            level: "MIDDLE",
            parentMatch: {
                claim1: claims[0],
                claim2: claims[1],
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
};

/**
 * Breadcrumbs for a top tournament.
 */
export const TopTournament: Story = {
    args: {
        tournament: {
            level: "TOP",
        },
    },
};
