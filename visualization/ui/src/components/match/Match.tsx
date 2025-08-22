import { Badge, Group, Stack, Text } from "@mantine/core";
import { useMemo, useState, type FC } from "react";
import { TimeSlider } from "../TimeSlider";
import { ClaimText } from "../tournament/ClaimText";
import type { Match, Tournament } from "../types";
import { MatchActionCard } from "./MatchActionCard";

export interface MatchViewProps {
    tournament: Tournament;
    match: Match;
}

const mcycleFormatter = new Intl.NumberFormat("en-US", {});

export const MatchView: FC<MatchViewProps> = (props) => {
    const { match, tournament } = props;
    const { level, startCycle, endCycle } = tournament;
    const range = `${mcycleFormatter.format(startCycle)} to ${mcycleFormatter.format(endCycle)}`;
    const [now, setNow] = useState<number | undefined>(undefined);
    const timestamps = useMemo(() => {
        return match.actions.map(({ timestamp }) => timestamp);
    }, [match]);

    return (
        <Stack>
            <Group>
                <Text>Level</Text>
                <Badge>{level}</Badge>
            </Group>
            <Group>
                <Text>Mcycle range</Text>
                <Text>{range}</Text>
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
