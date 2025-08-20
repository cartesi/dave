import type { Application, Epoch } from "../components/types";

export const applications: Application[] = [
    {
        address: "0x4c1E74EF88a75C24e49eddD9f70D82A94D19251c",
        name: "honeypot",
        consensusType: "PRT",
        state: "ENABLED",
        processedInputs: 8,
    },
    {
        address: "0x1590B6096A48A509286cdec2cb68E0DF292BFEf6",
        name: "comet",
        consensusType: "AUTHORITY",
        state: "ENABLED",
        processedInputs: 100,
    },
    {
        address: "0x70ac08179605AF2D9e75782b8DEcDD3c22aA4D0C",
        name: "disabled",
        consensusType: "QUORUM",
        state: "DISABLED",
        processedInputs: 15,
    },
    {
        address: "0x7285F04d1d779B77c63F61746C1dDa204E32aE45",
        name: "broken",
        consensusType: "PRT",
        state: "INOPERABLE",
        processedInputs: 45,
    },
];

/**
 * Epochs for each application
 */
export const epochs: Record<string, Epoch[]> = {
    honeypot: [
        {
            index: 1,
            inDispute: false,
            status: "FINALIZED",
        },
        {
            index: 2,
            inDispute: false,
            status: "FINALIZED",
        },
        {
            index: 3,
            inDispute: false,
            status: "FINALIZED",
        },
        {
            index: 4,
            inDispute: true,
            status: "SEALED",
        },
        {
            index: 5,
            inDispute: false,
            status: "OPEN",
        },
    ],
};
