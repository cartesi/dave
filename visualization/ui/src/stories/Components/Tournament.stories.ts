import type { Meta, StoryObj } from "@storybook/react-vite";
import { getUnixTime } from "date-fns";
import { fn } from "storybook/test";
import { TournamentView } from "../../components/tournament/Tournament";
import type { Tournament } from "../../components/types";
import { claim } from "../util";

const meta = {
    title: "Components/Tournament/Tournament",
    component: TournamentView,
    tags: ["autodocs"],
} satisfies Meta<typeof TournamentView>;

export default meta;
type Story = StoryObj<typeof meta>;

const timestamp = getUnixTime(Date.now());

const startCycle = 1837880065;
const endCycle = 2453987565;

const tournament: Tournament = {
    height: 48,
    level: "top",
    startCycle,
    endCycle,
    matches: [
        {
            claim1: claim(0),
            claim2: claim(1),
            timestamp: timestamp + 1,
            winner: 1,
            winnerTimestamp: timestamp + 2,
            actions: [],
        },
        {
            claim1: claim(2),
            claim2: claim(3),
            timestamp: timestamp + 3,
            actions: [
                {
                    type: "advance",
                    direction: 0,
                    timestamp: timestamp + 4,
                },
                {
                    type: "advance",
                    direction: 1,
                    timestamp: timestamp + 5,
                },
                {
                    type: "advance",
                    direction: 1,
                    timestamp: timestamp + 6,
                },
                {
                    type: "advance",
                    direction: 0,
                    timestamp: timestamp + 7,
                },
                {
                    type: "timeout",
                    timestamp: timestamp + 8,
                },
            ],
            tournament: {
                height: 27,
                level: "middle",
                startCycle: startCycle / 1024,
                endCycle: endCycle / 1024,
                matches: [
                    {
                        claim1: claim(7, 5),
                        claim2: claim(8, 4),
                        timestamp: timestamp + 8,
                        actions: [],
                    },
                    {
                        claim1: claim(9, 5),
                        claim2: claim(10, 4),
                        timestamp: timestamp + 10,
                        actions: [],
                    },
                ],
            },
        },
        {
            claim1: claim(4),
            claim2: claim(5),
            winner: 1,
            timestamp: timestamp + 5,
            winnerTimestamp: timestamp + 6,
            actions: [],
        },
        {
            claim1: claim(6),
            claim2: claim(4),
            timestamp: timestamp + 6,
            actions: [],
        },
    ],
    danglingClaim: claim(0),
};

export const Ongoing: Story = {
    args: {
        onClickMatch: fn(),
        tournament,
        parentMatches: [],
    },
};

export const NoChallengerYet: Story = {
    args: {
        onClickMatch: fn(),
        tournament: {
            height: 48,
            level: "top",
            startCycle,
            endCycle,
            winner: undefined,
            matches: [],
            danglingClaim: claim(0),
        },
        parentMatches: [],
    },
};

export const Finalized: Story = {
    args: {
        onClickMatch: fn(),
        tournament: {
            height: 48,
            level: "top",
            startCycle,
            endCycle,
            winner: claim(0),
            danglingClaim: claim(0),
            matches: [],
        },
        parentMatches: [],
    },
};

export const MidLevelDispute: Story = {
    args: {
        tournament: tournament.matches[1].tournament!,
        parentMatches: [{ claim1: claim(4), claim2: claim(5) }],
    },
};
