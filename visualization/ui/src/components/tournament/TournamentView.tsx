import { Group, Stack, Switch, Text, useMantineTheme } from "@mantine/core";
import { useState, type FC } from "react";
import { TbTrophyFilled } from "react-icons/tb";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { LongText } from "../LongText";
import { TournamentBreadcrumbSegment } from "../navigation/TournamentBreadcrumbSegment";
import type { Tournament } from "../types";
import { TournamentTable } from "./TournamentTable";

export interface TournamentViewProps {
    /**
     * The tournament to display.
     */
    tournament: Tournament;
}

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { tournament } = props;

    const theme = useMantineTheme();
    const gold = theme.colors.yellow[5];

    const { danglingClaim, endCycle, matches, startCycle, winner } = tournament;
    const [hideWinners, setHideWinners] = useState(false);

    return (
        <Stack>
            <Group>
                <Text>Level</Text>
                <TournamentBreadcrumbSegment
                    level={tournament.level}
                    variant="filled"
                />
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
            />
        </Stack>
    );
};
