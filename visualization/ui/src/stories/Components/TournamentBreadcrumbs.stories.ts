import type { Meta, StoryObj } from "@storybook/react-vite";
import { TournamentBreadcrumbs } from "../../components/TournamentBreadcrumbs";
import { claim } from "../util";

const meta = {
    title: "Components/Navigation/TournamentBreadcrumbs",
    component: TournamentBreadcrumbs,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof TournamentBreadcrumbs>;

export default meta;
type Story = StoryObj<typeof meta>;

/**
 * Breadcrumbs for a bottom tournament.
 */
export const BottomTournament: Story = {
    args: {
        parentMatches: [
            {
                claim1: claim(0),
                claim2: claim(1),
            },
            {
                claim1: claim(2),
                claim2: claim(3),
            },
        ],
    },
};

/**
 * Breadcrumbs for a middle tournament.
 */
export const MidTournament: Story = {
    args: {
        parentMatches: [
            {
                claim1: claim(0),
                claim2: claim(1),
            },
        ],
    },
};

/**
 * Breadcrumbs for a top tournament.
 */
export const TopTournament: Story = {
    args: {
        parentMatches: [],
    },
};
