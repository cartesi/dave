import type { Address, Hash } from "viem";

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
    level: "top" | "middle" | "bottom";
    startCycle: bigint;
    endCycle: bigint;
    rounds: Round[];
    winner?: Claim;
}
