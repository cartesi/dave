import type { Epoch } from "./Epoch";

export const openEpoch: Epoch = {
    index: 5,
    status: "OPEN",
    inDispute: false,
};

export const sealedEpoch: Epoch = {
    index: 4,
    status: "SEALED",
    inDispute: false,
};

export const closedEpoch: Epoch = {
    index: 3,
    status: "CLOSED",
    inDispute: false,
};

export const epochs: Epoch[] = [
    openEpoch,
    sealedEpoch,
    closedEpoch,
    { ...closedEpoch, index: 2 },
    { ...closedEpoch, index: 1 },
];
