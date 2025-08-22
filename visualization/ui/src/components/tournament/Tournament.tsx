import {
    Badge,
    Breadcrumbs,
    Group,
    Stack,
    Switch,
    Text,
    useMantineTheme,
} from "@mantine/core";
import { useMemo, useState, type FC, type ReactNode } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { LongText } from "../LongText";
import { TimeSlider } from "../TimeSlider";
import type { Match, Tournament } from "../types";
import { MatchMini } from "./MatchMini";
import { TournamentTable } from "./Table";

export interface TournamentViewProps {
    onClickMatch?: (match: Match) => void;
    tournament: Tournament;
}

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { onClickMatch, tournament } = props;
    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    const { danglingClaim, endCycle, level, matches, startCycle, winner } =
        tournament;
    const [hideWinners, setHideWinners] = useState(false);
    const [now, setNow] = useState(0);
    const timestamps = useMemo(() => {
        return tournament.matches
            .map((match) =>
                match.winnerTimestamp
                    ? [match.timestamp, match.winnerTimestamp]
                    : match.timestamp,
            )
            .flat();
    }, [tournament.matches]);

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
                <CycleRangeFormatted cycleRange={[startCycle, endCycle]} />
            </Group>
            <Group>
                <Text>Winner</Text>
                {!winner && <TbTrophyFilled size={24} color="lightgray" />}
                {winner && (
                    <Group gap="xs">
                        <TbTrophyFilled size={24} color={gold} />
                        <LongText value={winner.hash} ff="monospace" />
                    </Group>
                )}
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
                <TimeSlider timestamps={timestamps} onChange={setNow} />
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
