import type { Hex } from "viem";
import { syntheticDbInstance } from "./db";
import { findEpochTournament } from "./epoch.data";

interface DataMatchParams {
    applicationId: string | Hex;
    epochIndex: number;
    matchId: Hex;
}

export const findMatchTournament = ({
    applicationId,
    epochIndex,
    matchId,
}: DataMatchParams) => {
    const tournament = syntheticDbInstance.getSubTournament({
        applicationId,
        epochIndex,
        matchId,
    });

    if (!tournament) return null;

    tournament.matches =
        syntheticDbInstance.listTournamentMatches({
            applicationId,
            epochIndex,
            matchId,
            tournamentId: tournament.id,
        }) ?? [];

    return tournament;
};

interface GetMatch extends DataMatchParams {
    tournamentId: Hex;
}

export const getMatch = (params: GetMatch) => {
    return syntheticDbInstance.getMatch(params);
};

export const findMatch = (params: DataMatchParams) => {
    const tournament = findEpochTournament(
        params.applicationId,
        params.epochIndex,
    );
    if (!tournament) return null;

    return (
        tournament.matches?.find((match) => match.id === params.matchId) ?? null
    );
};
