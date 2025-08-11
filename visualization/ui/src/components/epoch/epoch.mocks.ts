import type { Epoch } from "./Epoch";

export const openEpoch: Epoch = {
    index: 8,
    status: "OPEN",
    inDispute: false,
};

export const sealedEpoch: Epoch = {
    index: 7,
    status: "SEALED",
    inDispute: false,
};

export const closedEpoch: Epoch = {
    index: 6,
    status: "CLOSED",
    inDispute: false,
};

export const epochs: Epoch[] = [openEpoch, sealedEpoch, closedEpoch];
