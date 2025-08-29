import type { Meta, StoryObj } from "@storybook/react-vite";
import { getUnixTime } from "date-fns";
import { fn } from "storybook/test";
import { keccak256, toBytes, zeroAddress } from "viem";
import { TournamentView } from "../../components/tournament/Tournament";
import type { Claim, Tournament } from "../../components/types";

const meta = {
    title: "Components/Tournament/Tournament",
    component: TournamentView,
    tags: ["autodocs"],
} satisfies Meta<typeof TournamentView>;

export default meta;
type Story = StoryObj<typeof meta>;

const timestamp = getUnixTime(Date.now());

const randomClaim = (i: number, c?: Pick<Claim, "parentClaim">): Claim => ({
    hash: keccak256(toBytes(i)),
    claimer: zeroAddress,
    parentClaim: c?.parentClaim,
});

const startCycle = 1837880065;
const endCycle = 2453987565;

const tournament: Tournament = {
    height: 48,
    level: "top",
    startCycle,
    endCycle,
    matches: [],
};

tournament.matches.push(
    {
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        timestamp: timestamp + 1,
        winner: 1,
        winnerTimestamp: timestamp + 2,
        actions: [],
        parentTournament: tournament,
    },
    {
        claim1: randomClaim(2),
        claim2: randomClaim(3),
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
        parentTournament: tournament,
    },
    {
        claim1: randomClaim(4),
        claim2: randomClaim(5),
        winner: 1,
        timestamp: timestamp + 5,
        winnerTimestamp: timestamp + 6,
        actions: [],
        parentTournament: tournament,
    },
    {
        claim1: randomClaim(6),
        claim2: randomClaim(4),
        timestamp: timestamp + 6,
        actions: [],
        parentTournament: tournament,
    },
);
tournament.danglingClaim = randomClaim(0);

const mid: Tournament = {
    height: 27,
    level: "middle",
    startCycle: startCycle / 1024,
    endCycle: endCycle / 1024,
    parentMatch: tournament.matches[1],
    matches: [],
};
mid.matches.push(
    {
        claim1: randomClaim(7, {
            parentClaim: mid.parentMatch?.claim1,
        }),
        claim2: randomClaim(8, {
            parentClaim: mid.parentMatch?.claim2,
        }),
        timestamp: timestamp + 8,
        actions: [],
        parentTournament: mid,
    },
    {
        claim1: randomClaim(9, {
            parentClaim: mid.parentMatch?.claim2,
        }),
        claim2: randomClaim(10, {
            parentClaim: mid.parentMatch?.claim1,
        }),
        timestamp: timestamp + 10,
        actions: [],
        parentTournament: mid,
    },
);
tournament.matches[1].tournament = mid;

export const Ongoing: Story = {
    args: {
        onClickMatch: fn(),
        tournament,
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
            danglingClaim: randomClaim(0),
        },
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
            winner: randomClaim(0),
            danglingClaim: randomClaim(0),
            matches: [],
        },
    },
};

export const MidLevelDispute: Story = {
    args: {
        tournament: mid,
    },
};
