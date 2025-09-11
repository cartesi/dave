import type { Hex } from "viem";
import { syntheticDbInstance } from "./db";

export const getEpoch = (applicationId: string | Hex, epochIndex: number) => {
    return syntheticDbInstance.getEpoch(applicationId, epochIndex);
};

export const findEpochTournament = (
    applicationId: string | Hex,
    epochIndex: number,
) => {
    const tournament = syntheticDbInstance.getTournament({
        applicationId,
        epochIndex,
    });
    if (tournament) {
        tournament.matches =
            syntheticDbInstance.listTournamentMatches({
                applicationId,
                epochIndex,
                tournamentId: tournament.id,
            }) ?? [];
    }

    return tournament;
};
