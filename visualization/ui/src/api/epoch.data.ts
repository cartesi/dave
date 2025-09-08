import type { Hex } from "viem";
import { findApplication } from "./application.data";

export const getEpoch = (applicationId: string | Hex, epochIndex: number) => {
    const application = findApplication(applicationId);

    if (isNaN(epochIndex)) return null;

    return (
        application?.epochs.find((epoch) => epoch.index === epochIndex) ?? null
    );
};

export const findEpochTournament = (
    applicationId: string | Hex,
    epochIndex: number,
) => {
    const epoch = getEpoch(applicationId, epochIndex);
    if (!epoch || !epoch.tournament) return null;

    return epoch.tournament;
};
