import { Divider, Stack } from "@mantine/core";
import type { FC } from "react";
import { useNavigate, useParams } from "react-router";
import {
    routePathBuilder,
    type RoutePathParams,
} from "../../routes/routePathBuilder";
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
}

export const TournamentRound: FC<TournamentRoundProps> = (props) => {
    const params = useParams<RoutePathParams>();
    const navigate = useNavigate();
    const { danglingClaim, hideWinners, index, matches } = props;
    const onMatchClick = (match: Match) => {
        const url = routePathBuilder.matchDetail({
            ...params,
            matchId: match.id,
        });

        navigate(url);
    };

    return (
        <Stack>
            <Divider label={`Round ${index + 1}`} />
            {matches.map((match) =>
                hideWinners && match.winner !== undefined && match.claim2 ? (
                    <MatchLoserCard
                        match={match}
                        onClick={() => onMatchClick(match)}
                    />
                ) : hideWinners && match.winner !== undefined ? undefined : (
                    <MatchCard
                        match={match}
                        onClick={() => onMatchClick(match)}
                    />
                ),
            )}
            {danglingClaim && <ClaimCard claim={danglingClaim} />}
        </Stack>
    );
};
