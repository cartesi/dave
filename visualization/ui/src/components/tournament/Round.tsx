import { Divider, Stack } from "@mantine/core";
import type { FC } from "react";
import type { Match } from "../types";
import { MatchCard } from "./MatchCard";
import { MatchLoserCard } from "./MatchLoserCard";

export interface TournamentRoundProps {
    index: number;
    matches: Match[];
    hideWinners?: boolean;
    now?: number;
}

export const TournamentRound: FC<TournamentRoundProps> = ({
    index,
    hideWinners,
    matches,
    now,
}) => {
    return (
        <Stack>
            <Divider label={`Round ${index + 1}`} />
            {matches.map((match) =>
                hideWinners && match.winner !== undefined && match.claim2 ? (
                    <MatchLoserCard match={match} now={now} />
                ) : hideWinners && match.winner !== undefined ? undefined : (
                    <MatchCard match={match} now={now} />
                ),
            )}
        </Stack>
    );
};
