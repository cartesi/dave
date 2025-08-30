import type { Meta, StoryObj } from "@storybook/react-vite";
import type { Claim, Tournament } from "../../components/types";
import { TournamentPage } from "../../view/tournament/Tournament";
import * as TournamentStories from "../Components/Tournament.stories";
import { applications } from "../data";
import { claim, randomMatches } from "../util";

const meta = {
    title: "Pages/Tournament",
    component: TournamentPage,
    tags: ["autodocs"],
} satisfies Meta<typeof TournamentPage>;

export default meta;
type Story = StoryObj<typeof meta>;

export const TopLevelClosed: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: TournamentStories.NoChallengerYet.args.tournament,
        parentMatches: [],
    },
};

export const TopLevelFinalized: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[3],
        tournament: TournamentStories.Finalized.args.tournament,
        parentMatches: [],
    },
};

export const TopLevelDispute: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: TournamentStories.Ongoing.args.tournament,
        parentMatches: [],
    },
};

/**
 * Create random claims
 */
const now = Math.floor(Date.now() / 1000);
const claims: Claim[] = Array.from({ length: 128 }).map((_, i) => claim(i));

const randomTournament: Tournament = {
    startCycle: 1837880065,
    endCycle: 2453987565,
    height: 48,
    level: "top",
    matches: [],
    danglingClaim: undefined,
};
randomMatches(now, randomTournament, claims);

export const TopLevelLargeDispute: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: randomTournament,
        parentMatches: [],
    },
};

export const MidLevelDispute: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: TournamentStories.MidLevelDispute.args.tournament,
        parentMatches: [{ claim1: claim(4), claim2: claim(5) }],
    },
};
