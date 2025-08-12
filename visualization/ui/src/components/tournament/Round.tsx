import { Divider, Stack } from "@mantine/core";
import type { FC } from "react";
import type { Match } from "../types";
import { MatchCard } from "./Match";

export interface TournamentRoundProps {
    index: number;
    matches: Match[];
}

export const TournamentRound: FC<TournamentRoundProps> = ({
    index,
    matches,
}) => {
    return (
        <Stack>
            <Divider label={`Round ${index + 1}`} />
            {matches.map((match) => (
                <MatchCard match={match} />
            ))}
        </Stack>
    );
};
