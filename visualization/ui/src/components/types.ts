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

export type Cycle = number;
export type CycleRange = [Cycle, Cycle];

type MatchAdvance = {
    type: "advance";
    direction: 0 | 1;
};

type MatchTimeout = {
    type: "timeout";
};

type MatchSubTournament = {
    type: "match_sealed_inner_tournament_created";
    range: CycleRange;
};

type MatchLeafSealed = {
    type: "leaf_match_sealed";
    winner: 1 | 2;
};

type MatchEliminationTimeout = {
    type: "match_eliminated_by_timeout";
};

export type MatchAction = (
    | MatchAdvance
    | MatchTimeout
    | MatchSubTournament
    | MatchLeafSealed
    | MatchEliminationTimeout
) & { timestamp: number };

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
    height: number;
    level: "top" | "middle" | "bottom";
    startCycle: Cycle;
    endCycle: Cycle;
    parentMatch?: Match;
    matches: Match[];
    danglingClaim?: Claim; // claim that was not matched with another claim yet
    winner?: Claim;
}
