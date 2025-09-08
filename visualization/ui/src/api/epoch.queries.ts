import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import { NETWORK_DELAY } from "./constants";
import { findEpochTournament, getEpoch } from "./epoch.data";

interface EpochDetailParam {
    applicationId: string | Hex;
    epochIndex: number;
}

const queryKeys = {
    all: () => ["epochs"] as const,
    details: (appId: string | Hex) =>
        [...queryKeys.all(), "app", appId, "epoch"] as const,
    detail: ({ applicationId, epochIndex }: EpochDetailParam) =>
        [...queryKeys.details(applicationId), epochIndex] as const,
    tournament: (params: EpochDetailParam) =>
        [...queryKeys.detail(params), "tournament"] as const,
};

export const epochQueryKeys = queryKeys;

// FETCHERS

type GetEpochDetailsReturn = ReturnType<typeof getEpoch>;

const getEpochDetails = ({ applicationId, epochIndex }: EpochDetailParam) => {
    const promise = new Promise<{ epoch: GetEpochDetailsReturn }>((resolve) => {
        setTimeout(() => {
            const epoch = getEpoch(applicationId, epochIndex);
            resolve({ epoch });
        }, NETWORK_DELAY);
    });

    return promise;
};

type GetEpochTournamentReturn = ReturnType<typeof findEpochTournament>;
const getEpochTournament = (params: EpochDetailParam) => {
    const promise = new Promise<{ tournament: GetEpochTournamentReturn }>(
        (resolve) => {
            setTimeout(() => {
                const tournament = findEpochTournament(
                    params.applicationId,
                    params.epochIndex,
                );
                resolve({ tournament });
            }, NETWORK_DELAY);
        },
    );

    return promise;
};

// CUSTOM HOOKS

export const useGetEpoch = (params: EpochDetailParam) => {
    return useQuery({
        queryKey: queryKeys.detail(params),
        queryFn: () => getEpochDetails(params),
    });
};

export const useGetEpochTournament = (params: EpochDetailParam) => {
    return useQuery({
        queryKey: queryKeys.tournament(params),
        queryFn: () => getEpochTournament(params),
    });
};
