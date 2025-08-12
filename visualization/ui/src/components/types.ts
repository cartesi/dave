import type { Address, Hash, Hex } from "viem";

export type ApplicationState = "ENABLED" | "DISABLED" | "INOPERABLE";
export type ConsensusType = "PRT" | "QUORUM" | "AUTHORITY";

export interface Application {
    address: Hex;
    name: string;
    consensusType: ConsensusType;
    state: ApplicationState;
    processedInputs: number;
}

export type EpochStatus = "OPEN" | "SEALED" | "CLOSED";

export interface Epoch {
    index: number;
    status: EpochStatus;
    inDispute: boolean;
}

export interface Claim {
    hash: Hash;
    claimer: Address;
    timestamp: number;
}

export interface Match {
    claim1: Claim;
    claim2?: Claim;
    winner?: 1 | 2;
}

export interface Round {
    matches: Match[];
}

export interface Tournament {
    level: "TOP" | "MIDDLE" | "BOTTOM";
    startCycle: bigint;
    endCycle: bigint;
    rounds: Round[];
    winner?: Claim;
}
