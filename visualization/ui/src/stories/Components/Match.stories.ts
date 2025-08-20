import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchView } from "../../components/match/Match";
import * as TournamentStories from "./Tournament.stories";

const meta = {
    title: "Components/Match",
    component: MatchView,
} satisfies Meta<typeof MatchView>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Ongoing: Story = {
    args: {
        tournament: TournamentStories.Ongoing.args.tournament,
        match: TournamentStories.Ongoing.args.tournament.rounds[0].matches[1],
    },
};

/**
 * A match that no claimer has taken action yet.
 */
export const NoActions: Story = {
    args: {
        tournament: TournamentStories.Ongoing.args.tournament,
        match: TournamentStories.Ongoing.args.tournament.rounds[1].matches[1],
    },
};
