"""
A thin wrapper that runs cartesi-machine with whatever arguments it receives,
merges stdout + stderr, prints the combined log to stdout, and exits with the
same status code.
"""
import os
import sys, subprocess

def main():
    if len(sys.argv) < 2:
        print("Usage: cm_wrapper.py <cartesi-machine args…>", file=sys.stderr)
        sys.exit(1)

    cmd = ["/Users/kasom/projects/cartesi/machine-emulator/src/cartesi-machine.lua",
           "--ram-image=/Users/kasom/projects/cartesi/images/linux.bin",
           "--flash-drive=label:root,filename:/Users/kasom/projects/cartesi/images/rootfs.ext2",
           "--hash-tree-target=risc0"
          ] + sys.argv[1:]

    env = os.environ.copy()
    build_dir = "/Users/kasom/projects/cartesi/machine-emulator/src"
    env["LUA_CPATH"] = f"{build_dir}/?.so;;" + env.get("LUA_CPATH", "")

    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)

    sys.stdout.write(proc.stdout)
    sys.stdout.write(proc.stderr)

    sys.exit(proc.returncode)

if __name__ == "__main__":
    main()
