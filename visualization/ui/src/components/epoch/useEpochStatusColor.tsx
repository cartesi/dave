import useRightColorShade from "../../hooks/useRightColorShade";
import type { Epoch, EpochStatus } from "../types";

export const getEpochStatusColor = (state: EpochStatus) => {
    switch (state) {
        case "OPEN":
            return "green";
        case "SEALED":
            return "cyan";
        case "FINALIZED":
        default:
            return "gray";
    }
};

export const useEpochStatusColor = (epoch: Epoch) => {
    const statusColor = useRightColorShade(getEpochStatusColor(epoch.status));
    const disputeColor = useRightColorShade("orange");
    return epoch.inDispute ? disputeColor : statusColor;
};
