import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import { NETWORK_DELAY } from "./constants";
import { getMatch } from "./match.data";

interface MatchDetailParam {
    applicationId: string | Hex;
    epochIndex: number;
    matchId: Hex;
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
};

export const matchQueryKeys = queryKeys;

// FETCHERS

type GetMatchDetailsReturn = ReturnType<typeof getMatch>;

const getMatchDetails = (params: MatchDetailParam) => {
    const promise = new Promise<{ match: GetMatchDetailsReturn }>((resolve) => {
        setTimeout(() => {
            const match = getMatch({
                applicationId: params.applicationId,
                epochIndex: params.epochIndex,
                matchId: params.matchId,
            });

            resolve({ match });
        }, NETWORK_DELAY);
    });

    return promise;
};

// CUSTOM HOOKS

export const useGetMatch = (params: MatchDetailParam) => {
    return useQuery({
        queryKey: queryKeys.detail(params),
        queryFn: () => getMatchDetails(params),
    });
};
