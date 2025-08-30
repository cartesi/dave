import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes } from "viem";
import { MatchActions } from "../../components/match/MatchActions";
import type { Claim, MatchAction } from "../../components/types";
import { mulberry32 } from "../util";

const meta = {
    title: "Components/Match/MatchActions",
    component: MatchActions,
    tags: ["autodocs"],
} satisfies Meta<typeof MatchActions>;

export default meta;
type Story = StoryObj<typeof meta>;

const randomClaim = (i: number, c?: Pick<Claim, "parentClaim">): Claim => ({
    hash: keccak256(toBytes(i)),
    parentClaim: c?.parentClaim,
});

const now = Math.floor(Date.now() / 1000);

/**
 * Complete scenario for a top match with a winner.
 */
const rng = mulberry32(0);
export const CompleteTop: Story = {
    args: {
        actions: [
            ...Array.from<number, MatchAction>({ length: 48 }, (_, i) => ({
                type: "advance",
                direction: rng() < 0.5 ? 0 : 1,
                timestamp: now - 7966 + i * 60,
            })),
            {
                type: "match_sealed_inner_tournament_created",
                range: [1837880065, 2453987565],
                timestamp: now - 3614,
            },
            {
                type: "leaf_match_sealed",
                timestamp: now - 1487,
                winner: 1,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};

/**
 * A match where both claimers are advancing.
 */
export const Bisections: Story = {
    args: {
        actions: [
            {
                type: "advance",
                direction: 0,
                timestamp: now - 3453,
            },
            {
                type: "advance",
                direction: 1,
                timestamp: now - 2134,
            },
            {
                type: "advance",
                direction: 1,
                timestamp: now - 1452,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 345,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 28,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};

/**
 * A match where first claimer has not taken action, and the second claimer has claimed victory.
 */
export const Timeout: Story = {
    args: {
        actions: [
            {
                type: "timeout",
                timestamp: now - 1000,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};

/**
 * A match where first claimer has advanced, second claimer has not taken action, and then first claimer has claimed victory..
 */
export const TimeoutSecond: Story = {
    args: {
        actions: [
            {
                type: "advance",
                direction: 0,
                timestamp: now - 2000,
            },
            {
                type: "timeout",
                timestamp: now - 1000,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};

/**
 * A match that has been eliminated by timeout with no action from both claimers.
 */
export const Elimination: Story = {
    args: {
        actions: [
            {
                type: "match_eliminated_by_timeout",
                timestamp: now - 1000,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};

/**
 * A match that has been eliminated by timeout with no action from both claimers after a few bisections.
 */
export const EliminationAfterBisections: Story = {
    args: {
        actions: [
            {
                type: "advance",
                direction: 0,
                timestamp: now - 3453,
            },
            {
                type: "advance",
                direction: 1,
                timestamp: now - 2134,
            },
            {
                type: "advance",
                direction: 1,
                timestamp: now - 1452,
            },
            {
                type: "match_eliminated_by_timeout",
                timestamp: now - 1000,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};

/**
 * A match that has reached the leaf level and will go to a sub-tournament.
 */

export const SubTournament: Story = {
    args: {
        actions: [
            {
                type: "advance",
                direction: 0,
                timestamp: now - 4032,
            },
            {
                type: "advance",
                direction: 1,
                timestamp: now - 3021,
            },
            {
                type: "advance",
                direction: 1,
                timestamp: now - 2101,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 1023,
            },
            {
                type: "match_sealed_inner_tournament_created",
                range: [1837880065, 2453987565],
                timestamp: now - 224,
            },
        ],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 4,
    },
};

/**
 * A bottom match that has reached the leaf level and has a winner.
 */
export const WinnerBottom: Story = {
    args: {
        actions: [
            {
                type: "advance",
                direction: 0,
                timestamp: now - 4032,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 3021,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 2101,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 1023,
            },
            {
                type: "leaf_match_sealed",
                timestamp: now - 224,
                winner: 1,
            },
        ],
        height: 5,
        claim1: randomClaim(0),
        claim2: randomClaim(1),
    },
};

/**
 * A top match that has reached the leaf level and the middle level has a winner.
 */
export const WinnerTop: Story = {
    args: {
        actions: [
            {
                type: "advance",
                direction: 0,
                timestamp: now - 4032,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 3021,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 2101,
            },
            {
                type: "advance",
                direction: 0,
                timestamp: now - 1023,
            },
            {
                type: "match_sealed_inner_tournament_created",
                range: [1837880065, 2453987565],
                timestamp: now - 224,
            },
            {
                type: "leaf_match_sealed",
                timestamp: now - 224,
                winner: 1,
            },
        ],
        height: 5,
        claim1: randomClaim(0),
        claim2: randomClaim(1),
    },
};

/**
 * A match that no claimer has taken action yet.
 */
export const NoActions: Story = {
    args: {
        actions: [],
        claim1: randomClaim(0),
        claim2: randomClaim(1),
        height: 48,
    },
};
