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

export type EpochStatus = "OPEN" | "SEALED" | "FINALIZED";

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

export type CycleRange = [bigint, bigint];

export type MatchAction =
    | {
          type: "advance";
          claimer: 1 | 2;
          timestamp: number;
          range: CycleRange;
      }
    | {
          type: "timeout";
          timestamp: number;
          winner: 1 | 2;
      }; // TODO: there are more action types

export interface Match {
    claim1: Claim;
    claim2?: Claim;
    winner?: 1 | 2;
    claim1Timestamp: number; // instant in time when claim1 joined the match
    claim2Timestamp?: number; // instant in time when claim2 joined the match
    winnerTimestamp?: number; // instant in time when match was resolved
    actions: MatchAction[];
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
