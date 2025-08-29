import { Divider, Group, Stack, Text } from "@mantine/core";
import { type FC } from "react";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import { MatchBreadcrumbs } from "../MatchBreadcrumbs";
import { ClaimText } from "../tournament/ClaimText";
import type { Match, Tournament } from "../types";
import { MatchActions } from "./MatchActions";

export interface MatchViewProps {
    tournament: Tournament;
    match: Match;
}

export const MatchView: FC<MatchViewProps> = (props) => {
    const { match, tournament } = props;
    const { claim1, claim2 } = match;
    const { startCycle, endCycle } = tournament;

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
            <Divider label="Actions" />
            <MatchActions
                actions={match.actions}
                claim1={claim1}
                claim2={claim2}
                height={tournament.height}
            />
        </Stack>
    );
};
