import type { Meta, StoryObj } from "@storybook/react-vite";
import { getUnixTime } from "date-fns";
import { claim, generateMatchID } from "../../stories/util";
import type { Tournament } from "../types";
import { TournamentView } from "./TournamentView";

const meta = {
    title: "Components/Tournament/TournamentView",
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
            id: generateMatchID(claim(0).hash, claim(1).hash),
            claim1: claim(0),
            claim2: claim(1),
            timestamp: timestamp + 1,
            winner: 1,
            winnerTimestamp: timestamp + 2,
            actions: [],
        },
        {
            id: generateMatchID(claim(2).hash, claim(3).hash),
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
                        id: generateMatchID(claim(7, 5).hash, claim(8, 4).hash),
                        claim1: claim(7, 5),
                        claim2: claim(8, 4),
                        timestamp: timestamp + 8,
                        actions: [],
                    },
                    {
                        id: generateMatchID(
                            claim(9, 5).hash,
                            claim(10, 4).hash,
                        ),
                        claim1: claim(9, 5),
                        claim2: claim(10, 4),
                        timestamp: timestamp + 10,
                        actions: [],
                    },
                ],
            },
        },
        {
            id: generateMatchID(claim(4).hash, claim(5).hash),
            claim1: claim(4),
            claim2: claim(5),
            winner: 1,
            timestamp: timestamp + 5,
            winnerTimestamp: timestamp + 6,
            actions: [],
        },
        {
            id: generateMatchID(claim(6).hash, claim(4).hash),
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
        tournament,
    },
};

export const NoChallengerYet: Story = {
    args: {
        tournament: {
            height: 48,
            level: "top",
            startCycle,
            endCycle,
            winner: undefined,
            matches: [],
            danglingClaim: claim(0),
        },
    },
};

export const Finalized: Story = {
    args: {
        tournament: {
            height: 48,
            level: "top",
            startCycle,
            endCycle,
            winner: claim(0),
            danglingClaim: claim(0),
            matches: [],
        },
    },
};

export const MidLevelDispute: Story = {
    args: {
        tournament: tournament.matches[1].tournament!,
    },
};
