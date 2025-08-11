import { Group, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import type { Tournament } from "../types";
import { TournamentTable } from "./Table";

export interface TournamentViewProps {
    tournament: Tournament;
}

const mcycleFormatter = new Intl.NumberFormat("en-US", {});

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { tournament } = props;
    const { level, startCycle, endCycle, rounds, winner } = tournament;

    return (
        <Stack>
            <Group gap={5}>
                <Text>Level</Text>
                <Text>{level}</Text>
            </Group>
            <Group gap={5}>
                <Text>Mcycle range</Text>
                <Text>{mcycleFormatter.format(startCycle)}</Text>
                <Text>-</Text>
                <Text>{mcycleFormatter.format(endCycle)}</Text>
            </Group>
            <Group gap={5}>
                <Text>Winner</Text>
                <Text>{winner?.hash ?? "-"}</Text>
            </Group>
            <TournamentTable rounds={rounds} />
        </Stack>
    );
};
