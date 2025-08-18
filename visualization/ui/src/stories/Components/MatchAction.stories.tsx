import { Container, Stack } from "@mantine/core";
import { useViewportSize } from "@mantine/hooks";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { keccak256, toBytes, zeroAddress } from "viem";
import MatchAction from "../../components/tournament/MatchAction";
import type { Claim, CycleRange } from "../../components/types";

const meta = {
    title: "Components/MatchAction",
    component: MatchAction,
    parameters: {
        layout: "fullscreen",
    },
} satisfies Meta<typeof MatchAction>;

export default meta;
type Story = StoryObj<typeof meta>;

type Props = Parameters<typeof MatchAction>[0];

const WithContainer = (props: Props) => {
    const { height } = useViewportSize();

    return (
        <Container h={height}>
            <Stack justify="center" h={height}>
                <MatchAction {...props} />
            </Stack>
        </Container>
    );
};

type ListProps = {
    matchActions: Props[];
};

const MatchActionList = (props: ListProps) => {
    const { height } = useViewportSize();
    const { matchActions } = props;

    return (
        <Container h={height}>
            <Stack justify="center" h={height}>
                {matchActions.map((action, i) => (
                    <MatchAction {...action} key={i} />
                ))}
            </Stack>
        </Container>
    );
};

const tournamentCycleRange: CycleRange = [1837880065n, 2453987565n];
const bisectionRangeOne: CycleRange = [2295760130n, 2300000000n];
const bisectionRangeTwo: CycleRange = [2675760130n, 1300000000n];
const bisectionRangeThree: CycleRange = [1837880060n, 1300000000n];
const simpleClaim: Claim = {
    claimer: zeroAddress,
    hash: keccak256(toBytes(1)),
    timestamp: Date.now(),
};

export const Initial: Story = {
    render: WithContainer,
    args: {
        isInitial: true,
        tournamentCycleRange: tournamentCycleRange,
        bisectionCycleRange: tournamentCycleRange,
    },
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
        claim: {
            ...simpleClaim,
            hash: keccak256(toBytes(10)),
        },
        tournamentCycleRange,
        bisectionCycleRange: bisectionRangeTwo,
    },
};

export const ClaimCWithWrongBisectionRange: Story = {
    render: WithContainer,
    args: {
        claim: simpleClaim,
        tournamentCycleRange,
        bisectionCycleRange: bisectionRangeThree,
    },
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

export const MultipleActions: CustomStory = {
    render: MatchActionList,
    args: {
        matchActions: [
            {
                isInitial: true,
                tournamentCycleRange: tournamentCycleRange,
                bisectionCycleRange: tournamentCycleRange,
            },
            {
                claim: simpleClaim,
                tournamentCycleRange,
                bisectionCycleRange: bisectionRangeOne,
            },
            {
                claim: {
                    ...simpleClaim,
                    hash: keccak256(toBytes(10)),
                },
                tournamentCycleRange,
                bisectionCycleRange: bisectionRangeTwo,
            },
        ],
    },
};
