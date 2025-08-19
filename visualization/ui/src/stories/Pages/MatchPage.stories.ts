import type { Meta, StoryObj } from "@storybook/react-vite";
import { MatchPage } from "../../view/match/Match";
import { Ongoing } from "../Components/Tournament.stories";
import { applications, epochs } from "../data";

const meta = {
    title: "Pages/Match",
    component: MatchPage,
} satisfies Meta<typeof MatchPage>;

export default meta;
type Story = StoryObj<typeof meta>;

export const TopLevelMatch: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: Ongoing.args.tournament,
        match: Ongoing.args.tournament.rounds[0].matches[0],
    },
};
