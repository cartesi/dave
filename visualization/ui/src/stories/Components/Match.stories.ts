import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchView } from "../../components/match/Match";
import * as MatchActionsStories from "./MatchActions.stories";
import * as TournamentStories from "./Tournament.stories";

const meta = {
    title: "Components/Match/Match",
    component: MatchView,
} satisfies Meta<typeof MatchView>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);

export const Ongoing: Story = {
    args: {
        height: 48,
        match: {
            ...TournamentStories.Ongoing.args.tournament.matches[1],
            actions: MatchActionsStories.Bisections.args.actions,
        },
        now,
        parentMatches: [],
        range: [1837880065, 2453987565],
    },
};

/**
 * A match that no claimer has taken action yet.
 */
export const NoActions: Story = {
    args: {
        height: 48,
        match: {
            ...TournamentStories.Ongoing.args.tournament.matches[1],
            actions: [],
        },
        now,
        parentMatches: [],
        range: [1837880065, 2453987565],
    },
};
