import useRightColorShade from "../../hooks/useRightColorShade";
import type { Epoch, EpochStatus } from "../types";

export const getEpochStatusColor = (state: EpochStatus) => {
    switch (state) {
        case "OPEN":
        case "CLOSED":
        case "FINALIZED":
            return state.toLowerCase();
        default:
            return "gray";
    }
};

export const useEpochStatusColor = (epoch: Epoch) => {
    const statusColor = useRightColorShade(getEpochStatusColor(epoch.status));
    const disputeColor = useRightColorShade("disputed");
    return epoch.inDispute ? disputeColor : statusColor;
};
