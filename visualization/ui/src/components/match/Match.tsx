import { Group, Stack, Text } from "@mantine/core";
import { useMemo, useState, type FC } from "react";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { MatchBreadcrumbs } from "../MatchBreadcrumbs";
import { TimeSlider } from "../TimeSlider";
import { ClaimText } from "../tournament/ClaimText";
import type { Match, Tournament } from "../types";
import { MatchActionCard } from "./MatchActionCard";

export interface MatchViewProps {
    tournament: Tournament;
    match: Match;
}

export const MatchView: FC<MatchViewProps> = (props) => {
    const { match, tournament } = props;
    const { startCycle, endCycle } = tournament;
    const [now, setNow] = useState<number | undefined>(undefined);
    const timestamps = useMemo(() => {
        return match.actions.map(({ timestamp }) => timestamp);
    }, [match]);

    return (
        <Stack>
            <Group>
                <Text>Level</Text>
                <MatchBreadcrumbs match={match} />
            </Group>
            <Group>
                <Text>Mcycle range</Text>
                <CycleRangeFormatted cycleRange={[startCycle, endCycle]} />
            </Group>
            <Group>
                <Text>Claims</Text>
                <Group gap="xs">
                    <ClaimText claim={match.claim1} />
                    <Text>vs</Text>
                    <ClaimText claim={match.claim2} />
                </Group>
            </Group>
            <Group>
                <Text>Time</Text>
                <TimeSlider timestamps={timestamps} onChange={setNow} />
            </Group>
            <Stack>
                {match.actions.map((action) => {
                    return !now || action.timestamp > now ? null : (
                        <MatchActionCard
                            action={action}
                            match={match}
                            tournament={tournament}
                        />
                    );
                })}
            </Stack>
        </Stack>
    );
};
