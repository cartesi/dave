import type { Meta, StoryObj } from "@storybook/react-vite";
import { Ongoing } from "../components/tournament/TournamentView.stories";
import { MatchPage } from "./MatchPage";

const meta = {
    title: "Pages/Match",
    component: MatchPage,
    tags: ["autodocs"],
} satisfies Meta<typeof MatchPage>;

export default meta;
type Story = StoryObj<typeof meta>;

const now = Math.floor(Date.now() / 1000);

export const TopLevelMatch: Story = {
    args: {
        tournament: Ongoing.args.tournament,
        match: Ongoing.args.tournament.matches[1],
        now,
    },
};
