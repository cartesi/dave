#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH= cd -- "${script_dir}/../.." && pwd -P)"
readonly repo_root

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dave-image-receipt.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fixture_repo="${fixture}/repo"
fake_bin="${fixture}/bin"
mkdir -p \
    "${fixture_repo}/script" \
    "${fixture_repo}/test/programs/script" \
    "${fixture_repo}/test/programs/echo/machine-image" \
    "$fake_bin"
cp "${repo_root}/script/machine-image-fingerprint.sh" "${fixture_repo}/script/"
cp "${repo_root}"/test/programs/script/build-*.sh \
    "${fixture_repo}/test/programs/script/"
printf 'kernel\n' > "${fixture_repo}/test/programs/linux.bin"
printf 'rootfs\n' > "${fixture_repo}/test/programs/rootfs.ext2"

cat > "${fake_bin}/cartesi-machine" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
    printf 'cartesi-machine test\n'
    exit 0
fi
exit 2
EOF
cat > "${fake_bin}/cartesi-machine-stored-hash" <<'EOF'
#!/usr/bin/env bash
printf '0x%s\n' '1111111111111111111111111111111111111111111111111111111111111111'
EOF
chmod +x "${fake_bin}/cartesi-machine" "${fake_bin}/cartesi-machine-stored-hash"

checker="${fixture_repo}/script/machine-image-fingerprint.sh"
export PATH="${fake_bin}:${PATH}"
export DAVE_EMULATOR_GITLINK=0123456789abcdef0123456789abcdef01234567

CDPATH= cd -- "$fixture_repo"

echo_inputs_before="$("$checker" inputs echo)"
printf '# unrelated producer edit\n' >> test/programs/script/build-honeypot.sh
echo_inputs_after="$("$checker" inputs echo)"
[[ "$echo_inputs_before" == "$echo_inputs_after" ]]

printf '# echo producer edit\n' >> test/programs/script/build-echo.sh
echo_inputs_changed="$("$checker" inputs echo)"
[[ "$echo_inputs_before" != "$echo_inputs_changed" ]]

cp "${repo_root}/test/programs/script/build-echo.sh" \
    test/programs/script/build-echo.sh
"$checker" capture echo >/dev/null
printf '# changed during build\n' >> test/programs/script/build-echo.sh
if "$checker" write echo >/dev/null 2>&1; then
    echo "error: write accepted a producer change after capture" >&2
    exit 1
fi

cp "${repo_root}/test/programs/script/build-echo.sh" \
    test/programs/script/build-echo.sh
"$checker" capture echo >/dev/null
"$checker" write echo >/dev/null
"$checker" verify echo >/dev/null
grep -Eq '^v2 echo [0-9a-f]{64} [0-9a-f]{64}$' \
    test/programs/echo/machine-image.fingerprint

printf 'v1 echo %064d %064d\n' 0 0 \
    > test/programs/echo/machine-image.fingerprint
if "$checker" verify echo >/dev/null 2>&1; then
    echo "error: verifier accepted a legacy receipt" >&2
    exit 1
fi

if "$checker" inputs unsupported >/dev/null 2>&1; then
    echo "error: checker accepted an unsupported program" >&2
    exit 1
else
    [[ $? -eq 2 ]]
fi

echo "machine-image fingerprint tests: passed"
