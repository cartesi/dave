import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchPage } from "../../pages/MatchPage";
import { Ongoing } from "../Components/TournamentView.stories";
import { applications } from "../data";

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
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: Ongoing.args.tournament,
        match: Ongoing.args.tournament.matches[1],
        now,
        parentMatches: [],
    },
};
