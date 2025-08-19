import { Container, Stack } from "@mantine/core";
import { useViewportSize } from "@mantine/hooks";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import MatchDetailCard from "../../components/match/MatchDetailCard";
import type { MatchLimitRangeCardProps } from "../../components/match/MatchLimitRangeCard";
import MatchLimitRangeCard from "../../components/match/MatchLimitRangeCard";
import type { Claim, CycleRange } from "../../components/types";

const meta = {
    title: "Components/MatchDetail",
    component: MatchDetailCard,
    parameters: {
        layout: "fullscreen",
    },
} satisfies Meta<typeof MatchDetailCard>;

export default meta;
type Story = StoryObj<typeof meta>;

type Props = Parameters<typeof MatchDetailCard>[0];

const WithContainer = (props: Props) => {
    const { height } = useViewportSize();

    return (
        <Container h={height}>
            <Stack justify="center" h={height}>
                <MatchDetailCard {...props} />
            </Stack>
        </Container>
    );
};

const half = (tuple: CycleRange) => (tuple[0] + tuple[1]) / 2n;

const tournamentCycleRange: CycleRange = [1837880065n, 2453987565n];
const bisectionRangeOne: CycleRange = [half(tournamentCycleRange), 2453987565n];
const bisectionRangeTwo: CycleRange = [
    bisectionRangeOne[0],
    half(bisectionRangeOne),
];
const bisectionRangeThree: CycleRange = [
    half(bisectionRangeTwo),
    bisectionRangeTwo[1],
];
const bisectionRangeFour: CycleRange = [
    half(bisectionRangeThree),
    bisectionRangeThree[1],
];

const simpleClaim: Claim = {
    claimer: zeroAddress,
    hash: keccak256(toBytes(1)),
    timestamp: Date.now(),
};

const simpleClaimTwo: Claim = {
    claimer: zeroAddress,
    hash: keccak256(toBytes(10)),
    timestamp: Date.now(),
};

export const ClaimABisection: Story = {
    render: WithContainer,
    args: {
        claim: simpleClaim,
        tournamentCycleRange,
        bisectionCycleRange: bisectionRangeOne,
    },
};

export const ClaimBBisection: Story = {
    render: WithContainer,
    args: {
        claim: simpleClaimTwo,
        tournamentCycleRange,
        bisectionCycleRange: bisectionRangeTwo,
    },
};

type ListProps = {
    matchLimitRange: MatchLimitRangeCardProps;
    matchActions: Props[];
};

const MatchActionList = (props: ListProps) => {
    const { height } = useViewportSize();
    const { matchActions, matchLimitRange } = props;

    return (
        <Container h={height}>
            <Stack justify="center" h={height}>
                <MatchLimitRangeCard cycleRange={matchLimitRange.cycleRange} />
                {matchActions.map((action, i) => (
                    <MatchDetailCard {...action} key={i} />
                ))}
            </Stack>
        </Container>
    );
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const customMeta = {
    title: "Components/MatchAction",
    component: MatchActionList,
    parameters: {
        layout: "fullscreen",
    },
} satisfies Meta<typeof MatchActionList>;

type CustomStory = StoryObj<typeof customMeta>;

export const MultipleClaimEntries: CustomStory = {
    render: MatchActionList,
    args: {
        matchLimitRange: { cycleRange: tournamentCycleRange },
        matchActions: [
            {
                claim: simpleClaim,
                tournamentCycleRange,
                bisectionCycleRange: bisectionRangeOne,
            },
            {
                claim: simpleClaimTwo,
                tournamentCycleRange,
                bisectionCycleRange: bisectionRangeTwo,
            },
            {
                claim: simpleClaim,
                bisectionCycleRange: bisectionRangeThree,
                tournamentCycleRange,
            },
            {
                claim: simpleClaimTwo,
                tournamentCycleRange,
                bisectionCycleRange: bisectionRangeFour,
            },
        ],
    },
};
