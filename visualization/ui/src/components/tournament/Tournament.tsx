import {
    Badge,
    Breadcrumbs,
    Group,
    Slider,
    Stack,
    Switch,
    Text,
} from "@mantine/core";
import { useEffect, useState, type FC, type ReactNode } from "react";
import { LongText } from "../LongText";
import type { Match, Tournament } from "../types";
import { MatchMini } from "./MatchMini";
import { TournamentTable } from "./Table";

export interface TournamentViewProps {
    onClickMatch?: (match: Match) => void;
    tournament: Tournament;
}

const mcycleFormatter = new Intl.NumberFormat("en-US", {});
const dateFormatter = new Intl.DateTimeFormat("en-US", {
    dateStyle: "short",
    timeStyle: "medium",
});

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { onClickMatch, tournament } = props;
    const { danglingClaim, endCycle, level, matches, startCycle, winner } =
        tournament;
    const range = `${mcycleFormatter.format(startCycle)} → ${mcycleFormatter.format(endCycle)}`;
    const [hideWinners, setHideWinners] = useState(false);
    const [minTimestamp, setMinTimestamp] = useState(0);
    const [maxTimestamp, setMaxTimestamp] = useState(0);
    const [timeMarks, setTimeMarks] = useState<{ value: number }[]>([]);
    const [now, setNow] = useState(0);

    useEffect(() => {
        // collect all timestamps from all matches
        const timestamps = tournament.matches
            .map((match) =>
                match.winnerTimestamp
                    ? [match.timestamp, match.winnerTimestamp]
                    : match.timestamp,
            )
            .flat();

        if (timestamps.length > 0) {
            // find the minimum and maximum timestamps
            const min = Math.min(...timestamps);
            const max = Math.max(...timestamps);

            // set the state
            setMinTimestamp(min);
            setMaxTimestamp(max);
            setNow(max);

            // set slider marks
            setTimeMarks(timestamps.map((value) => ({ value })));
        }
    }, [tournament]);

    // build the breadcrumb of the tournament hierarchy
    const parents: ReactNode[] = [];
    let parentMatch = tournament.parentMatch;
    while (parentMatch) {
        parents.unshift(<MatchMini match={parentMatch} />);
        parents.unshift(
            <Badge key={parentMatch.parentTournament.level} variant="default">
                {parentMatch.parentTournament.level}
            </Badge>,
        );
        parentMatch = parentMatch.parentTournament.parentMatch;
    }

    return (
        <Stack>
            <Group>
                <Text>Level</Text>
                <Breadcrumbs separator="→">
                    {parents}
                    <Badge key={level}>{level}</Badge>
                </Breadcrumbs>
            </Group>
            <Group>
                <Text>Mcycle range</Text>
                <Text>{range}</Text>
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
                <Text>Time</Text>
                <Slider
                    defaultValue={maxTimestamp}
                    disabled={now === undefined}
                    min={minTimestamp}
                    max={maxTimestamp}
                    marks={timeMarks}
                    restrictToMarks
                    value={now}
                    onChange={(value) => setNow(value)}
                    w={300}
                    label={(value) =>
                        dateFormatter.format(new Date(value * 1000))
                    }
                />
            </Group>
            <TournamentTable
                danglingClaim={danglingClaim}
                matches={matches}
                hideWinners={hideWinners}
                now={now}
                onClickMatch={onClickMatch}
            />
        </Stack>
    );
};
