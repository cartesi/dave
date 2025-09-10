import { Divider, Group, Stack, Text } from "@mantine/core";
import { type FC } from "react";
import { ClaimText } from "../ClaimText";
import { CycleRangeFormatted } from "../CycleRangeFormatted";
import type { CycleRange, Match } from "../types";
import { MatchActions } from "./MatchActions";

export interface MatchViewProps {
    /**
     * The match to display.
     */
    match: Match;

    /**
     * The height of the tournament bisection tree.
     */
    height: number;

    /**
     * The current timestamp.
     */
    now: number;

    /**
     * The cycle range of the match tournament.
     */
    range: CycleRange;
}

export const MatchView: FC<MatchViewProps> = (props) => {
    const { height, match, now, range } = props;
    const { claim1, claim2 } = match;

    return (
        <Stack>
            <Group>
                <Text>Mcycle range</Text>
                <CycleRangeFormatted range={range} />
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
                height={height}
                now={now}
            />
        </Stack>
    );
};
