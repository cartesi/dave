import { Group, Stack, Switch, Text, useMantineTheme } from "@mantine/core";
import { useState, type FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { LongText } from "../LongText";
import { TournamentBreadcrumbs } from "../navigation/TournamentBreadcrumbs";
import type { Match, Tournament } from "../types";
import { TournamentTable } from "./TournamentTable";

export interface TournamentViewProps {
    /**
     * Callback when a match is clicked. Useful for navigating to the match page.
     */
    onClickMatch?: (match: Match) => void;

    /**
     * The tournament to display.
     */
    tournament: Tournament;

    /**
     * The parent matches of the tournament.
     */
    parentMatches: Pick<Match, "claim1" | "claim2">[];
}

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { onClickMatch, tournament, parentMatches } = props;

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    const { danglingClaim, endCycle, matches, startCycle, winner } = tournament;
    const [hideWinners, setHideWinners] = useState(false);

    return (
        <Stack>
            <Group>
                <Text>Level</Text>
                <TournamentBreadcrumbs parentMatches={parentMatches} />
            </Group>
            <Group>
                <Text>Mcycle range</Text>
                <CycleRangeFormatted range={[startCycle, endCycle]} />
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
            <TournamentTable
                danglingClaim={danglingClaim}
                matches={matches}
                hideWinners={hideWinners}
                onClickMatch={onClickMatch}
            />
        </Stack>
    );
};
