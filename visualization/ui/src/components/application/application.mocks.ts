import type { Application } from "./Application";

export const HoneypotDapp: Application = {
    address: "0x4c1E74EF88a75C24e49eddD9f70D82A94D19251c",
    name: "Honeypot",
    consensusType: "PRT",
    state: "ENABLED",
    processedInputs: 8,
};

export const applications: Application[] = [
    {
        address: "0x4c1E74EF88a75C24e49eddD9f70D82A94D19251c",
        name: "Honeypot",
        consensusType: "PRT",
        state: "ENABLED",
        processedInputs: 8,
    },
    {
        address: "0x1590B6096A48A509286cdec2cb68E0DF292BFEf6",
        name: "Comet",
        consensusType: "AUTHORITY",
        state: "ENABLED",
        processedInputs: 100,
    },
    {
        address: "0x70ac08179605AF2D9e75782b8DEcDD3c22aA4D0C",
        name: "SunDapp",
        consensusType: "QUORUM",
        state: "DISABLED",
        processedInputs: 15,
    },
    {
        address: "0x7285F04d1d779B77c63F61746C1dDa204E32aE45",
        name: "BrokenDapp",
        consensusType: "PRT",
        state: "INOPERABLE",
        processedInputs: 45,
    },
];
