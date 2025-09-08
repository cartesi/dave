import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import type { Application, Epoch } from "../components/types";
import { findApplication } from "./application.data";
import { NETWORK_DELAY } from "./constants";

export const applicationKeys = {
    all: ["apps"] as const,
    lists: () => [...applicationKeys.all, "list"] as const,
    details: () => [...applicationKeys.all, "details"] as const,
    detail: (id: string | Hex) => [...applicationKeys.details(), id] as const,
    epochs: (id: string | Hex) =>
        [...applicationKeys.detail(id), "epochs"] as const,
    epochDetail: (appId: string | Hex, epochIndex: number) =>
        [...applicationKeys.epochs(appId), epochIndex] as const,
};

// FETCHERS

const listApplications = () => {
    const promise = new Promise<{ applications: Application[] }>((resolve) => {
        setTimeout(() => {
            const app = findApplication("honeypot") as Application;
            resolve({ applications: [app] });
        }, NETWORK_DELAY);
    });

    return promise;
};

const getApplication = (id: string | Hex) => {
    const promise = new Promise<{ application: Application | undefined }>(
        (resolve) => {
            setTimeout(() => {
                const app = findApplication(id);
                resolve({ application: app });
            }, NETWORK_DELAY);
        },
    );

    return promise;
};

const listApplicationEpochs = (id: string | Hex) => {
    const promise = new Promise<{ epochs: Epoch[] }>((resolve) => {
        setTimeout(() => {
            const app = findApplication(id);
            resolve({ epochs: app?.epochs ?? [] });
        }, NETWORK_DELAY);
    });

    return promise;
};

// CUSTOM HOOKS

export const useListApplications = () => {
    return useQuery({
        queryKey: applicationKeys.lists(),
        queryFn: listApplications,
    });
};

export const useGetApplication = (id: string | Hex) => {
    return useQuery({
        queryKey: applicationKeys.detail(id),
        queryFn: () => getApplication(id),
    });
};

export const useListApplicationEpochs = (id: string | Hex) => {
    return useQuery({
        queryKey: applicationKeys.epochs(id),
        queryFn: () => listApplicationEpochs(id),
    });
};
