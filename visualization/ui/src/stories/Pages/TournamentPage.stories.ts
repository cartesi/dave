import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import type { Claim } from "../../components/types";
import { TournamentPage } from "../../view/tournament/Tournament";
import * as TournamentStories from "../Components/Tournament.stories";
import { applications } from "../data";
import { randomTournament } from "../util";

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
    },
};

export const TopLevelFinalized: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[3],
        tournament: TournamentStories.Finalized.args.tournament,
    },
};

export const TopLevelDispute: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: TournamentStories.Ongoing.args.tournament,
    },
};

/**
 * Create random claims
 */
const startTimestamp = Math.floor(Date.now() / 1000) * 1000;
const rootClaims: Claim[] = Array.from({ length: 128 }).map((_, i) => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    timestamp: startTimestamp + i * 1000, // XXX: improve this time distribution
}));

export const TopLevelLargeDispute: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: randomTournament(
            {
                level: "TOP",
                startCycle: 1837880065n,
                endCycle: 2453987565n,
            },
            rootClaims,
        ),
    },
};

export const MidLevelDispute: Story = {
    args: {
        application: applications[0],
        epoch: applications[0].epochs[4],
        tournament: TournamentStories.MidLevelDispute.args.tournament,
    },
};
