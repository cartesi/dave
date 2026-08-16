#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH= cd -- "${script_dir}/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dave-devnet-fingerprint-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

fixture="${fixture_root}/repo"
tools="${fixture_root}/bin"
checker="${fixture}/script/devnet-fingerprint.sh"
stdout="${fixture_root}/stdout"
stderr="${fixture_root}/stderr"

mkdir -p "$fixture/script" "$tools"
cp "${repo_root}/script/devnet-fingerprint.sh" "$checker"

source_roots=(
    prt/contracts/src
    prt/contracts/script
    prt/contracts/dependencies
    cartesi-rollups/contracts/src
    cartesi-rollups/contracts/script
    cartesi-rollups/contracts/dependencies
    machine/step/src
)
config_roots=(
    prt/contracts
    cartesi-rollups/contracts
    cartesi-rollups/contracts/dependencies/cartesi-rollups-contracts-3.0.0-alpha.6
)

for root in "${source_roots[@]}"; do
    mkdir -p "${fixture}/${root}"
    printf 'contract Fixture {}\n' >"${fixture}/${root}/Fixture.sol"
done
for root in "${config_roots[@]}"; do
    mkdir -p "${fixture}/${root}"
    printf '{"src":"src","script":"script","remappings":[]}\n' \
        >"${fixture}/${root}/.fake-forge-config.json"
done
printf 'prt lock\n' >"${fixture}/prt/contracts/soldeer.lock"
printf 'rollups lock\n' >"${fixture}/cartesi-rollups/contracts/soldeer.lock"
printf 'abstract contract BaseDeploymentScript {}\n' \
    >"${fixture}/prt/contracts/script/BaseDeploymentScript.sol"
printf 'contract DeploymentScript {}\n' \
    >"${fixture}/prt/contracts/script/Deployment.s.sol"
printf 'contract DeploymentScript {}\n' \
    >"${fixture}/cartesi-rollups/contracts/script/Deployment.s.sol"
printf '#!/usr/bin/env bash\n' \
    >"${fixture}/cartesi-rollups/contracts/script/build-devnet.sh"
printf '#!/usr/bin/env bash\n' \
    >"${fixture}/cartesi-rollups/contracts/script/deploy.sh"
mkdir -p "${fixture}/cartesi-rollups/contracts/deployments/31337"
printf '{"state":"ready"}\n' \
    >"${fixture}/cartesi-rollups/contracts/state.json"
printf '{"address":"0x1"}\n' \
    >"${fixture}/cartesi-rollups/contracts/deployments/31337/Contract.json"

cat >"${tools}/forge" <<'EOF'
#!/usr/bin/env bash
if [[ "${DAVE_TEST_FORGE_FAIL:-}" == "yes" ]]; then
    printf 'broken forge\n' >&2
    exit 7
fi
case "${1:-}" in
    --version) printf '%s\n' "${DAVE_TEST_FORGE_VERSION:-forge 1.0}" ;;
    config) cat .fake-forge-config.json ;;
    *) exit 2 ;;
esac
EOF
cat >"${tools}/anvil" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${DAVE_TEST_ANVIL_VERSION:-anvil 1.0}"
EOF
chmod +x "${tools}/forge" "${tools}/anvil"

run_checker() {
    PATH="${tools}:$PATH" /bin/bash "$checker" "$@"
}

expect_status() {
    local expected=$1
    local actual=0
    shift

    set +e
    run_checker "$@" >"$stdout" 2>"$stderr"
    actual=$?
    set -e
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'expected status %s, got %s for:' "$expected" "$actual" >&2
        printf ' %q' "$@" >&2
        printf '\nstdout:\n' >&2
        cat "$stdout" >&2
        printf 'stderr:\n' >&2
        cat "$stderr" >&2
        exit 1
    fi
}

digest="$(run_checker inputs)"
run_checker write "$digest" "${fixture}/cartesi-rollups/contracts" >/dev/null
expect_status 0 verify "${fixture}/cartesi-rollups/contracts"

# Non-production neighbors do not invalidate the deployment bundle.
mkdir -p "${fixture}/prt/contracts/test" \
    "${fixture}/prt/contracts/dependencies/test"
printf 'documentation only\n' >"${fixture}/prt/contracts/README.md"
printf 'contract Ignored {}\n' >"${fixture}/prt/contracts/test/Ignored.t.sol"
printf 'contract IgnoredDependency {}\n' \
    >"${fixture}/prt/contracts/dependencies/test/Ignored.sol"
[[ "$(run_checker inputs)" == "$digest" ]]

# Every retained production class invalidates the old receipt.
printf 'contract Changed {}\n' >"${fixture}/prt/contracts/src/Fixture.sol"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf 'contract Fixture {}\n' >"${fixture}/prt/contracts/src/Fixture.sol"
expect_status 0 verify "${fixture}/cartesi-rollups/contracts"

printf 'contract ChangedDependency {}\n' \
    >"${fixture}/prt/contracts/dependencies/Fixture.sol"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf 'contract Fixture {}\n' \
    >"${fixture}/prt/contracts/dependencies/Fixture.sol"

printf 'contract ChangedStep {}\n' >"${fixture}/machine/step/src/Fixture.sol"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf 'contract Fixture {}\n' >"${fixture}/machine/step/src/Fixture.sol"

printf 'contract ChangedDeployment {}\n' \
    >"${fixture}/prt/contracts/script/Deployment.s.sol"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf 'contract DeploymentScript {}\n' \
    >"${fixture}/prt/contracts/script/Deployment.s.sol"

printf 'changed rollups lock\n' \
    >"${fixture}/cartesi-rollups/contracts/soldeer.lock"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf 'rollups lock\n' \
    >"${fixture}/cartesi-rollups/contracts/soldeer.lock"

printf '{"src":"changed","script":"script","remappings":[]}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf '{"src":"src","script":"script","remappings":[]}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"

printf '{"src":"src","script":"script","remappings":[],"always_use_create_2_factory":true}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf '{"src":"src","script":"script","remappings":[]}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"

printf '{"src":"src","script":"script","remappings":[],"extra_args":["--metadata-hash","none"]}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf '{"src":"src","script":"script","remappings":[],"gas_price":42}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf '{"src":"src","script":"script","remappings":[]}\n' \
    >"${fixture}/prt/contracts/.fake-forge-config.json"

export DAVE_TEST_FORGE_VERSION='forge 2.0'
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
unset DAVE_TEST_FORGE_VERSION

printf '{"state":"changed"}\n' \
    >"${fixture}/cartesi-rollups/contracts/state.json"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf '{"state":"ready"}\n' \
    >"${fixture}/cartesi-rollups/contracts/state.json"

printf '{"address":"0x2"}\n' \
    >"${fixture}/cartesi-rollups/contracts/deployments/31337/Contract.json"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
printf '{"address":"0x1"}\n' \
    >"${fixture}/cartesi-rollups/contracts/deployments/31337/Contract.json"

# Missing producer inputs are setup failures; broken tools are checker failures.
mv "${fixture}/machine/step/src" "${fixture}/machine/step/src.missing"
expect_status 1 inputs
mv "${fixture}/machine/step/src.missing" "${fixture}/machine/step/src"
export DAVE_TEST_FORGE_FAIL=yes
expect_status 2 verify "${fixture}/cartesi-rollups/contracts"
unset DAVE_TEST_FORGE_FAIL

printf 'not a fingerprint\n' \
    >"${fixture}/cartesi-rollups/contracts/state.fingerprint"
expect_status 1 verify "${fixture}/cartesi-rollups/contracts"
expect_status 2 unknown-mode

printf 'devnet fingerprint tests: ok\n'
