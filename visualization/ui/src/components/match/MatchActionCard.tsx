import {
    Card,
    Grid,
    GridCol,
    Group,
    Text,
    useMantineTheme,
    type CardProps,
} from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { type FC } from "react";
import { ClaimText } from "../tournament/ClaimText";
import type { Match, MatchAction, Tournament } from "../types";
import CycleRangeGraph from "./CycleRangeGraph";

interface Props extends CardProps {
    tournament: Tournament;
    match: Match;
    action: MatchAction;
    midText?: string;

    /**
     * Simulated current time.
     * When not provided, all actions are shown as is.
     * When provided, the actions are shown as they were at the given time.
     */
    now?: number;
}

export const MatchActionCard: FC<Props> = (props) => {
    const {
        action,
        match,
        midText = "Bisection",
        now,
        tournament,
        ...cardProps
    } = props;

    if (now !== undefined) {
        // simulated time is defined, return empty if action is in the future
        if (action.timestamp > now) {
            return;
        }
    }

    // if action is an advance, assign the claim as claim1 or claim2
    const claim =
        action.type === "advance"
            ? action.claimer === 1
                ? match.claim1
                : match.claim2
            : undefined;

    const range = action.type === "advance" ? action.range : undefined;

    const theme = useMantineTheme();
    const isSmallDevice = useMediaQuery(`(max-width:${theme.breakpoints.sm})`);
    const wrapClaimGroup = isSmallDevice ? "wrap" : "nowrap";

    return (
        <Card withBorder shadow="sm" radius="lg" {...cardProps}>
            <Grid align="center" columns={12}>
                <GridCol span={{ base: 12, sm: 5 }}>
                    <Group justify="space-between" wrap={wrapClaimGroup}>
                        {claim && <ClaimText claim={claim} />}
                        <Text ff="monospace" fw="bold" tt="uppercase">
                            {midText}
                        </Text>
                    </Group>
                </GridCol>
                <GridCol span={{ base: 12, sm: 7 }}>
                    {range && (
                        <CycleRangeGraph
                            cycleLimits={[
                                tournament.startCycle,
                                tournament.endCycle,
                            ]}
                            cycleRange={range}
                        />
                    )}
                </GridCol>
            </Grid>
        </Card>
    );
};
