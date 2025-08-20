import { Divider, Stack } from "@mantine/core";
import type { FC } from "react";
import type { Match } from "../types";
import { MatchCard } from "./MatchCard";
import { MatchLoserCard } from "./MatchLoserCard";

export interface TournamentRoundProps {
    hideWinners?: boolean;
    index: number;
    matches: Match[];

    /**
     * Simulated current time.
     * When not provided, the round shows all matches.
     * When provided, the matchs are displayed as the simulated time.
     */
    now?: number;
    onClickMatch?: (match: Match) => void;
}

export const TournamentRound: FC<TournamentRoundProps> = ({
    hideWinners,
    index,
    matches,
    now,
    onClickMatch,
}) => {
    return (
        <Stack>
            <Divider label={`Round ${index + 1}`} />
            {matches.map((match) =>
                hideWinners && match.winner !== undefined && match.claim2 ? (
                    <MatchLoserCard
                        match={match}
                        now={now}
                        onClick={() => onClickMatch?.(match)}
                    />
                ) : hideWinners && match.winner !== undefined ? undefined : (
                    <MatchCard
                        match={match}
                        now={now}
                        onClick={() => onClickMatch?.(match)}
                    />
                ),
            )}
        </Stack>
    );
};
