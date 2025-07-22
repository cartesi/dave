#!/usr/bin/env python3

import sys
import subprocess
import tempfile
import os
from eth_abi import encode
from pathlib import Path

PROVER_CLI_PATH = "/Users/kasom/projects/cartesi/machine-emulator/risc0/rust/target/debug/cartesi-risc0-cli"

def main():
    # sys.argv = ['zk_proof.py', start_hash, end_hash, num_cycles, step_log_hex]
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <startHash> <endHash> <numCycles> <stepLogHex>", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(PROVER_CLI_PATH):
        error_message = f"Prover executable not found at: {PROVER_CLI_PATH}"
        return_error(error_message)

    start_hash = sys.argv[1].replace("0x", "")
    end_hash = sys.argv[2].replace("0x", "")
    num_cycles = sys.argv[3]
    step_log_file = Path(sys.argv[4]).expanduser()

    with step_log_file.open("rb") as f:
       step_log_bytes = f.read()

    try:
        with tempfile.NamedTemporaryFile(delete=True, suffix=".log") as tmp_step_log_file, \
             tempfile.NamedTemporaryFile(delete=True, suffix=".bin") as tmp_receipt_file:

            tmp_step_log_file.write(step_log_bytes)
            tmp_step_log_file.flush()

            step_log_path = tmp_step_log_file.name
            receipt_path = tmp_receipt_file.name

            command = [
                PROVER_CLI_PATH,
                "prove",
                start_hash,
                step_log_path,
                num_cycles,
                end_hash,
                receipt_path
            ]

            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode == 0:
                receipt_bytes = tmp_receipt_file.read()
                return_success(receipt_bytes)
            else:
                error_output = f"Prover failed with exit code {result.returncode}.\n" \
                               f"Stderr: {result.stderr.strip()}\n" \
                               f"Stdout: {result.stdout.strip()}"
                return_error(error_output)

    except Exception as e:
        return_error(f"An unexpected error occurred in the python script: {e}")


def return_success(payload_bytes: bytes):
    status   = b'\x00' * 32
    message  = b'\x00' * 32
    encoded  = encode(['bytes32', 'bytes32', 'bytes'],
                      [status, message, payload_bytes])

    sys.stdout.write("0x" + encoded.hex())
    sys.stdout.flush()
    sys.exit(0)


def return_error(error_message: str):
    status   = (1).to_bytes(32, 'big')
    message  = error_message.encode()[:32].ljust(32, b'\x00')
    encoded  = encode(['bytes32', 'bytes32', 'bytes'],
                      [status, message, b''])

    sys.stdout.write("0x" + encoded.hex())
    sys.stdout.flush()
    sys.exit(1)


if __name__ == "__main__":
    main()
