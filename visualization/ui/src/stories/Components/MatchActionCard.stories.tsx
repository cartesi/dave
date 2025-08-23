import type { Meta, StoryObj } from "@storybook/react-vite";
import { getUnixTime } from "date-fns";
import { MatchActionCard } from "../../components/match/MatchActionCard";
import * as TournamentStories from "./Tournament.stories";

const meta = {
    title: "Components/MatchActionCard",
    component: MatchActionCard,
    parameters: {
        layout: "centered",
    },
    tags: ["autodocs"],
} satisfies Meta<typeof MatchActionCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const tournament = TournamentStories.Ongoing.args.tournament;
const match = tournament.matches[1];
const timestamp = getUnixTime(Date.now());

export const ClaimABisection: Story = {
    args: {
        action: {
            type: "advance",
            claimer: 1,
            range: [
                tournament.startCycle,
                (tournament.startCycle + tournament.endCycle) / 2,
            ],
            timestamp: timestamp,
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
                (tournament.startCycle + tournament.endCycle) / 2,
            ],
            timestamp: timestamp,
        },
        match,
        tournament,
    },
};

export const Timeout: Story = {
    args: {
        action: {
            type: "timeout",
            claimer: 2,
            timestamp: timestamp,
        },
        match,
        tournament,
    },
};

export const Sealed: Story = {
    args: {
        action: {
            type: "match_sealed_inner_tournament_created",
            claimer: 1,
            tournament: TournamentStories.MidLevelDispute.args.tournament,
            timestamp: timestamp,
        },
        match,
        tournament,
    },
};

export const LeafSealed: Story = {
    args: {
        action: {
            type: "leaf_match_sealed",
            timestamp: timestamp,
            claimer: 1,
        },
        match: TournamentStories.MidLevelDispute.args.tournament.matches[0],
        tournament: {
            level: "BOTTOM",
            endCycle:
                TournamentStories.MidLevelDispute.args.tournament.endCycle /
                1024,
            startCycle:
                TournamentStories.MidLevelDispute.args.tournament.startCycle /
                1024,
            matches: [],
            parentMatch: match,
        },
    },
};
