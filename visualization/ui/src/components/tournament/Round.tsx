import { Divider, Stack } from "@mantine/core";
import type { FC } from "react";
import type { Claim, Match } from "../types";
import { ClaimCard } from "./ClaimCard";
import { MatchCard } from "./MatchCard";
import { MatchLoserCard } from "./MatchLoserCard";

export interface TournamentRoundProps {
    /**
     * The claim that was not matched with another claim yet.
     */
    danglingClaim?: Claim;

    /**
     * Whether to hide the winners.
     */
    hideWinners?: boolean;

    /**
     * The index of the round.
     */
    index: number;

    /**
     * The matches to display.
     */
    matches: Match[];

    /**
     * Simulated current time.
     * When not provided, the round shows all matches.
     * When provided, the matchs are displayed as the simulated time.
     */
    now?: number;

    /**
     * Callback when a match is clicked.
     */
    onClickMatch?: (match: Match) => void;
}

export const TournamentRound: FC<TournamentRoundProps> = (props) => {
    const { danglingClaim, hideWinners, index, matches, now, onClickMatch } =
        props;

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
            {danglingClaim && <ClaimCard claim={danglingClaim} />}
        </Stack>
    );
};
