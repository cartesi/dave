import type { Hex } from "viem";
import { findEpochTournament } from "./epoch.data";

interface GetMatchParams {
    applicationId: string | Hex;
    epochIndex: number;
    matchId: Hex;
}

export const getMatch = (params: GetMatchParams) => {
    const tournament = findEpochTournament(
        params.applicationId,
        params.epochIndex,
    );
    if (!tournament) return null;

    return (
        tournament.matches?.find((match) => match.id === params.matchId) ?? null
    );
};
