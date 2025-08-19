import { Badge, Group, Slider, Stack, Text } from "@mantine/core";
import { useEffect, useState, type FC } from "react";
import { ClaimCard } from "../tournament/ClaimCard";
import type { Match, Tournament } from "../types";

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
    const [now, setNow] = useState(0);

    useEffect(() => {
        // collect all timestamps from all matches
        const timestamps = tournament.rounds
            .map((round) => {
                return round.matches
                    .map((match) => {
                        const timestamps = [match.claim1Timestamp];
                        if (match.claim2Timestamp) {
                            timestamps.push(match.claim2Timestamp);
                        }
                        if (match.winnerTimestamp) {
                            timestamps.push(match.winnerTimestamp);
                        }
                        return timestamps;
                    })
                    .flat();
            })
            .flat();

        // find the minimum and maximum timestamps
        const min = Math.min(...timestamps);
        const max = Math.max(...timestamps);

        // set the state
        setMinTimestamp(min);
        setMaxTimestamp(max);
        setNow(max);
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
                    <ClaimCard claim={match.claim1} />
                    <Text>vs</Text>
                    {match.claim2 && <ClaimCard claim={match.claim2} />}
                </Group>
            </Group>
            <Group>
                <Text>Time Travel</Text>
                <Slider
                    defaultValue={maxTimestamp}
                    min={minTimestamp}
                    max={maxTimestamp}
                    step={1000}
                    value={now}
                    onChange={(value) => setNow(value)}
                    w={300}
                    label={(value) => dateFormatter.format(new Date(value))}
                />
            </Group>
        </Stack>
    );
};
