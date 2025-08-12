import { Badge, Group, Stack, Text } from "@mantine/core";
import type { FC } from "react";
import { LongText } from "../LongText";
import type { Tournament } from "../types";
import { TournamentTable } from "./Table";

export interface TournamentViewProps {
    tournament: Tournament;
}

const mcycleFormatter = new Intl.NumberFormat("en-US", {});

export const TournamentView: FC<TournamentViewProps> = (props) => {
    const { tournament } = props;
    const { level, startCycle, endCycle, rounds, winner } = tournament;
    const range = `${mcycleFormatter.format(startCycle)} to ${mcycleFormatter.format(endCycle)}`;

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
            <TournamentTable rounds={rounds} />
        </Stack>
    );
};
