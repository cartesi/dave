import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import { applications } from "../../stories/data";
import type { Application, Epoch } from "../types";

const SYNTH_DELAY = 300 as const;

const applicationKeys = {
    all: ["apps"] as const,
    lists: () => [...applicationKeys.all, "list"] as const,
    details: () => [...applicationKeys.all, "details"] as const,
    detail: (id: string | Hex) => [...applicationKeys.details(), id] as const,
    epochs: (id: string | Hex) =>
        [...applicationKeys.detail(id), "epochs"] as const,
    epochDetail: (appId: string | Hex, epochIndex: number) =>
        [...applicationKeys.epochs(appId), epochIndex] as const,
};

const findApp = (id: string | Hex) => {
    return applications.find((app) => {
        return (
            app.address.toLowerCase() === id.toLowerCase() ||
            app.name.toLowerCase() === id.toLowerCase()
        );
    });
};

// FETCHERS

const listApplication = () => {
    const promise = new Promise<{ applications: Application[] }>((resolve) => {
        setTimeout(() => {
            resolve({ applications: [applications[0]] });
        }, SYNTH_DELAY);
    });

    return promise;
};

const getApplication = (id: string | Hex) => {
    const promise = new Promise<{ application: Application | undefined }>(
        (resolve) => {
            setTimeout(() => {
                const app = findApp(id);
                resolve({ application: app });
            }, SYNTH_DELAY);
        },
    );

    return promise;
};

const listApplicationEpochs = (id: string | Hex) => {
    const promise = new Promise<{ epochs: Epoch[] }>((resolve) => {
        setTimeout(() => {
            const app = findApp(id);
            resolve({ epochs: app?.epochs ?? [] });
        }, SYNTH_DELAY);
    });

    return promise;
};

// CUSTOM HOOKS

export const useListApplications = () => {
    return useQuery({
        queryKey: applicationKeys.lists(),
        queryFn: listApplication,
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
