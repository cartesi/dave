import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import { NETWORK_DELAY } from "./constants";
import { findInputs } from "./inputs.data";

type ListInputsParams = { applicationId: string | Hex; epochIndex: number };

const queryKeys = {
    all: () => ["inputs"] as const,
    lists: (appId: string | Hex, epochIndex: number) =>
        [...queryKeys.all(), "app", appId, "epoch", epochIndex] as const,
    list: ({ applicationId, epochIndex }: ListInputsParams) =>
        [...queryKeys.lists(applicationId, epochIndex), "list"] as const,
};

export const inputQueryKeys = queryKeys;

// FETCHERS
type ListInputsReturn = ReturnType<typeof findInputs>;
const listInputs = ({ applicationId, epochIndex }: ListInputsParams) => {
    const promise = new Promise<{ inputs: ListInputsReturn }>((resolve) => {
        setTimeout(() => {
            const inputs = findInputs({ applicationId, epochIndex });
            resolve({ inputs: inputs });
        }, NETWORK_DELAY);
    });

    return promise;
};

// CUSTOM HOOKS
export const useListInputs = (params: ListInputsParams) => {
    return useQuery({
        queryKey: queryKeys.list(params),
        queryFn: () => listInputs(params),
    });
};
