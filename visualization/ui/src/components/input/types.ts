import type { Hex } from "viem";

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
