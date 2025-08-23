import {
    Anchor,
    Badge,
    Card,
    Grid,
    GridCol,
    Group,
    Stack,
    Text,
    useMantineTheme,
    type CardProps,
} from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { fromUnixTime } from "date-fns";
import { type FC } from "react";
import { TbClockExclamation, TbLeafOff, TbTrophyFilled } from "react-icons/tb";
import { href, Link } from "react-router";
import useRightColorShade from "../../hooks/useRightColorShade";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { ClaimText } from "../tournament/ClaimText";
import type {
    Claim,
    CycleRange,
    Match,
    MatchAction,
    Tournament,
} from "../types";
import CycleRangeGraph from "./CycleRangeGraph";

type AdvanceActionProps = {
    claim: Claim;
    range: CycleRange;
    rangeLimit: CycleRange;
    text?: string;
};

const AdvanceAction: FC<AdvanceActionProps> = ({
    claim,
    range,
    rangeLimit,
    text = "Bisection",
}) => {
    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const wrapClaimGroup = isSmallDevice ? "wrap" : "nowrap";

    return (
        <Grid align="center" columns={12}>
            <GridCol span={{ base: 12, sm: 5 }}>
                <Group justify="space-between" wrap={wrapClaimGroup}>
                    <ClaimText claim={claim} />
                    <Text ff="monospace" fw="bold" tt="uppercase">
                        {text}
                    </Text>
                </Group>
            </GridCol>
            <GridCol span={{ base: 12, sm: 7 }}>
                <CycleRangeGraph cycleLimits={rangeLimit} cycleRange={range} />
            </GridCol>
        </Grid>
    );
};

type TimeoutActionProps = {
    claim: Claim;
    timestamp: number;
};

const dateFormatter = new Intl.DateTimeFormat("en-US", {
    dateStyle: "short",
    timeStyle: "medium",
});

const TimeoutAction: FC<TimeoutActionProps> = ({ claim, timestamp }) => {
    const theme = useMantineTheme();
    const warningColor = useRightColorShade("orange");
    const text = "timeout";

    return (
        <Stack>
            <Group justify="space-between">
                <ClaimText claim={claim} />
                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            <Group justify="flex-end" gap="xs">
                <TbClockExclamation
                    size={theme.other.mdIconSize}
                    color={warningColor}
                />
                <Text c={warningColor} size="sm">
                    {dateFormatter.format(fromUnixTime(timestamp))}
                </Text>
            </Group>
        </Stack>
    );
};

type SealedActionProps = {
    claim: Claim;
    tournament: Tournament;
};

const SealedAction: FC<SealedActionProps> = ({ claim, tournament }) => {
    const text = "Match Sealed";
    // refactor: demonstration purpose it probably needs to be the tournament address instead of Mcycles.
    const middleTournamentPath = href(
        `mt/${tournament.startCycle}-${tournament.endCycle}`,
    );

    const theme = useMantineTheme();
    const cycleRange: CycleRange = [tournament.startCycle, tournament.endCycle];

    return (
        <Stack>
            <Group justify="space-between">
                <ClaimText claim={claim} />
                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            <Group justify="flex-start">
                <Badge color="green">
                    New {tournament.level} Tournament Created
                </Badge>
            </Group>
            <Anchor to={{ pathname: middleTournamentPath }} component={Link}>
                <Group gap="xs" wrap="nowrap" align="center">
                    <TbTrophyFilled size={theme.other.mdIconSize} />
                    <Text tt="capitalize">Tournament</Text>
                    <CycleRangeFormatted cycleRange={cycleRange} />
                </Group>
            </Anchor>
        </Stack>
    );
};

type LeafMatchSealedActionProps = {
    timestamp: number;
    claim: Claim;
};

const LeaftMatchSealedAction: FC<LeafMatchSealedActionProps> = ({
    timestamp,
    claim,
}) => {
    const theme = useMantineTheme();
    const baseColor = useRightColorShade("cyan");
    const text = "Match Sealed";

    return (
        <Stack>
            <Group justify="space-between">
                <ClaimText claim={claim} />
                <Text ff="monospace" fw="bold" tt="uppercase" c="dimmed">
                    {text}
                </Text>
            </Group>
            <Group justify="flex-end" gap={3}>
                <TbLeafOff size={theme.other.mdIconSize} color={baseColor} />
                <Text c={baseColor} size="sm">
                    {dateFormatter.format(fromUnixTime(timestamp))}
                </Text>
            </Group>
        </Stack>
    );
};

interface Props extends CardProps {
    tournament: Tournament;
    match: Match;
    action: MatchAction;
}

export const MatchActionCard: FC<Props> = (props) => {
    const { action, match, tournament, ...cardProps } = props;

    return (
        <Card withBorder radius="md" {...cardProps}>
            {action.type === "advance" ? (
                <AdvanceAction
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    range={action.range}
                    rangeLimit={[tournament.startCycle, tournament.endCycle]}
                />
            ) : action.type === "match_sealed_inner_tournament_created" ? (
                <SealedAction
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    tournament={action.tournament}
                />
            ) : action.type === "timeout" ? (
                <TimeoutAction
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    timestamp={action.timestamp}
                />
            ) : action.type === "leaf_match_sealed" ? (
                <LeaftMatchSealedAction
                    claim={action.claimer === 1 ? match.claim1 : match.claim2}
                    timestamp={action.timestamp}
                />
            ) : (
                ""
            )}
        </Card>
    );
};
