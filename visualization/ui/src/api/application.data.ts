import type { Hex } from "viem";
import type { Application, Epoch } from "../components/types";
import { syntheticDbInstance } from "./db";

type ApplicationEpochs = Application & { epochs: Epoch[] };

export const findApplication = (
    id: string | Hex,
): ApplicationEpochs | undefined => {
    const app = syntheticDbInstance.getApplication(id);
    if (!app) return;

    const epochs = syntheticDbInstance.listEpochs(id) ?? [];

    return {
        ...app,
        epochs,
    };
};
