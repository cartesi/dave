import { Badge, Group, Slider, Stack, Switch, Text } from "@mantine/core";
import { useEffect, useState, type FC } from "react";
import { LongText } from "../LongText";
import type { Match, Tournament } from "../types";
import { TournamentTable } from "./Table";

export interface TournamentViewProps {
    tournament: Tournament;
    onClickMatch?: (match: Match) => void;
}

const mcycleFormatter = new Intl.NumberFormat("en-US", {});
const dateFormatter = new Intl.DateTimeFormat("en-US", {
    dateStyle: "short",
    timeStyle: "medium",
});

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { onClickMatch, tournament } = props;
    const { level, startCycle, endCycle, rounds, winner } = tournament;
    const range = `${mcycleFormatter.format(startCycle)} to ${mcycleFormatter.format(endCycle)}`;
    const [hideWinners, setHideWinners] = useState(false);
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
                <Group>
                    <Text>{range}</Text>
                </Group>
            </Group>
            <Group>
                <Text>Winner</Text>
                <LongText
                    value={winner?.hash ?? "(undefined)"}
                    shorten={winner?.hash ? 16 : false}
                    copyButton={!!winner?.hash}
                    ff="monospace"
                />
            </Group>
            <Switch
                label="Show only eliminated and pending matches"
                labelPosition="left"
                size="md"
                checked={hideWinners}
                onChange={(event) =>
                    setHideWinners(event.currentTarget.checked)
                }
            />
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
            <TournamentTable
                rounds={rounds}
                hideWinners={hideWinners}
                now={now}
                onClickMatch={onClickMatch}
            />
        </Stack>
    );
};
