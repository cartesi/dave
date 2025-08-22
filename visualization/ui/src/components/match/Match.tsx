import { Badge, Group, Slider, Stack, Text } from "@mantine/core";
import { useEffect, useState, type FC } from "react";
import { ClaimText } from "../tournament/ClaimText";
import type { Match, Tournament } from "../types";
import { MatchActionCard } from "./MatchActionCard";

export interface MatchViewProps {
    tournament: Tournament;
    match: Match;
}

const mcycleFormatter = new Intl.NumberFormat("en-US", {});
const dateFormatter = new Intl.DateTimeFormat("en-US", {
    dateStyle: "short",
    timeStyle: "medium",
});

export const MatchView: FC<MatchViewProps> = (props) => {
    const { match, tournament } = props;
    const { level, startCycle, endCycle } = tournament;
    const range = `${mcycleFormatter.format(startCycle)} to ${mcycleFormatter.format(endCycle)}`;
    const [minTimestamp, setMinTimestamp] = useState(0);
    const [maxTimestamp, setMaxTimestamp] = useState(0);
    const [now, setNow] = useState<number | undefined>(undefined);

    useEffect(() => {
        // collect all timestamps from all actions
        const timestamps = match.actions.map(({ timestamp }) => timestamp);
        if (timestamps.length > 0) {
            // find the minimum and maximum timestamps
            const min = Math.min(...timestamps);
            const max = Math.max(...timestamps);

            // set the state
            setMinTimestamp(min);
            setMaxTimestamp(max);
            setNow(max);
        }
    }, [tournament]);

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
                <Slider
                    defaultValue={maxTimestamp}
                    disabled={now === undefined}
                    min={minTimestamp}
                    max={maxTimestamp}
                    step={1000}
                    value={now}
                    onChange={(value) => setNow(value)}
                    w={300}
                    label={(value) =>
                        dateFormatter.format(new Date(value * 1000))
                    }
                />
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
