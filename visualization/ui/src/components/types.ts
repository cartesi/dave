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

export type EpochStatus = "OPEN" | "CLOSED" | "FINALIZED";

export interface Epoch {
    index: number;
    status: EpochStatus;
    inDispute: boolean;
}

export type InputStatus =
    | "NONE"
    | "ACCEPTED"
    | "REJECTED"
    | "EXCEPTION"
    | "MACHINE_HALTED"
    | "OUTPUTS_LIMIT_EXCEEDED"
    | "CYCLE_LIMIT_EXCEEDED"
    | "TIME_LIMIT_EXCEEDED"
    | "PAYLOAD_LENGTH_LIMIT_EXCEEDED";

export interface Input {
    status: InputStatus;
    index: number;
    epochIndex: number;
    sender: Hex;
    machineHash: Hex;
    outputHash: Hex;
    payload: Hex;
}

export interface Claim {
    hash: Hash;
    claimer: Address;
    parentClaim?: Claim;
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
    parentTournament: Tournament;
    tournament?: Tournament;
    claim1: Claim;
    claim2: Claim;
    winner?: 1 | 2;
    timestamp: number; // instant in time when match was created
    winnerTimestamp?: number; // instant in time when match was resolved (winner declared)
    actions: MatchAction[];
}

export interface Tournament {
    level: "TOP" | "MIDDLE" | "BOTTOM";
    startCycle: bigint;
    endCycle: bigint;
    parentMatch?: Match;
    matches: Match[];
    danglingClaim?: Claim; // claim that was not matched with another claim yet
    winner?: Claim;
}
