import type { Meta, StoryObj } from "@storybook/react-vite";
import { TournamentPage } from "../../view/tournament/Tournament";
import {
    Closed,
    NoChallengerYet,
    Ongoing,
} from "../Components/Tournament.stories";
import { applications, epochs } from "../data";

const meta = {
    title: "Pages/Tournament",
    component: TournamentPage,
} satisfies Meta<typeof TournamentPage>;

export default meta;
type Story = StoryObj<typeof meta>;

export const TopLevelSealed: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: NoChallengerYet.args.tournament,
    },
};

export const TopLevelClosed: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[3],
        tournament: Closed.args.tournament,
    },
};

export const TopLevelDispute: Story = {
    args: {
        application: applications[0],
        epoch: epochs.honeypot[4],
        tournament: Ongoing.args.tournament,
    },
};
