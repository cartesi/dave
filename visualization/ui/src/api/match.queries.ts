import { useQuery } from "@tanstack/react-query";
import { omit } from "ramda";
import type { Hex } from "viem";
import { NETWORK_DELAY } from "./constants";
import { findMatch, findMatchTournament, getMatch } from "./match.data";

interface MatchDetailParam {
    applicationId: string | Hex;
    epochIndex: number;
    matchId: Hex;
}
interface MatchParams extends MatchDetailParam {
    tournamentId: Hex;
}

const queryKeys = {
    all: () => ["matches"] as const,
    app: ({ applicationId }: MatchDetailParam) =>
        [...queryKeys.all(), "app", applicationId] as const,
    epoch: (params: MatchDetailParam) =>
        [...queryKeys.app(params), "epoch", params.epochIndex] as const,
    tournament: (params: MatchDetailParam) =>
        [...queryKeys.epoch(params), "tournament"] as const,
    detail: (params: MatchDetailParam) =>
        [...queryKeys.tournament(params), "match", params.matchId] as const,
    subTournament: (params: MatchDetailParam) =>
        [
            ...queryKeys.epoch(params),
            "match",
            params.matchId,
            "subTournament",
        ] as const,
    match: (params: MatchParams) =>
        [
            ...queryKeys.tournament(params),
            params.tournamentId,
            "match",
            params.matchId,
        ] as const,
};

export const matchQueryKeys = queryKeys;

// FETCHERS

type GetMatchDetailsReturn = ReturnType<typeof findMatch>;

const getMatchDetails = (params: MatchDetailParam) => {
    const promise = new Promise<{ match: GetMatchDetailsReturn }>((resolve) => {
        setTimeout(() => {
            const match = findMatch({
                applicationId: params.applicationId,
                epochIndex: params.epochIndex,
                matchId: params.matchId,
            });

            resolve({ match });
        }, NETWORK_DELAY);
    });

    return promise;
};

type FetchMatchReturn = ReturnType<typeof getMatch>;
const fetchMatch = (params: MatchParams) => {
    const promise = new Promise<{ match: FetchMatchReturn }>((resolve) => {
        setTimeout(() => {
            const match = getMatch(params);
            resolve({ match });
        }, NETWORK_DELAY);
    });

    return promise;
};

type GetMatchTournamentReturn = ReturnType<typeof findMatchTournament>;

const getMatchTournament = (params: MatchDetailParam) => {
    const promise = new Promise<{ tournament: GetMatchTournamentReturn }>(
        (resolve) => {
            setTimeout(() => {
                const tournament = findMatchTournament(params);
                resolve({ tournament });
            }, NETWORK_DELAY);
        },
    );

    return promise;
};

// CUSTOM HOOKS

export const useGetMatch = (params: MatchDetailParam) => {
    return useQuery({
        queryKey: queryKeys.detail(params),
        queryFn: () => getMatchDetails(params),
    });
};

interface UseFindMatchParams extends MatchDetailParam {
    tournamentId: Hex;
    enabled?: boolean;
}

export const useFindMatch = (params: UseFindMatchParams) => {
    return useQuery({
        queryKey: queryKeys.match(params),
        queryFn: () => fetchMatch(omit(["enabled"], params)),
        enabled: params.enabled ?? true,
    });
};

export const useGetMatchTournament = (params: MatchDetailParam) => {
    return useQuery({
        queryKey: queryKeys.subTournament(params),
        queryFn: () => getMatchTournament(params),
    });
};
