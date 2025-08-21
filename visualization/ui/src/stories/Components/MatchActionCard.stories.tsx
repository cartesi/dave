import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchActionCard } from "../../components/match/MatchActionCard";
import * as TournamentStories from "./Tournament.stories";

const meta = {
    title: "Components/MatchActionCard",
    component: MatchActionCard,
    parameters: {
        layout: "centered",
    },
} satisfies Meta<typeof MatchActionCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const tournament = TournamentStories.Ongoing.args.tournament;
const match = tournament.matches[1];

export const ClaimABisection: Story = {
    args: {
        action: {
            type: "advance",
            claimer: 1,
            range: [
                tournament.startCycle,
                (tournament.startCycle + tournament.endCycle) / 2n,
            ],
            timestamp: Date.now(),
        },
        match,
        tournament,
    },
};

export const ClaimBBisection: Story = {
    args: {
        action: {
            type: "advance",
            claimer: 2,
            range: [
                tournament.startCycle,
                (tournament.startCycle + tournament.endCycle) / 2n,
            ],
            timestamp: Date.now(),
        },
        match,
        tournament,
    },
};
