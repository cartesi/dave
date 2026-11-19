# Releasing a version

Every deployed contract reports the release version through `version()`,
compiled from `prt/contracts/src/Version.sol`. `just codegen` generates that
file from the version variables in the root justfile, which are the single
source of the version. CI's `check-version` job fails on every trigger when
`Version.sol` does not match the justfile, and on a tag push when the tag is
not `v` followed by `just print-version`; the artifact builds depend on the
success of these pre-flight checks.

Every release comes with a version bump, and therefore bytecode change. Since
we use deterministic deployment, this means that all deployment addresses
change on every release.

## Release

1. Update `MAJOR_VERSION`, `MINOR_VERSION`, `PATCH_VERSION` and/or
   `PRE_RELEASE` in the root justfile. Leave `PRE_RELEASE` empty for a final
   release.
2. In `CHANGELOG.md`, rename the `## Unreleased` heading to `## v` followed by
   the output of `just print-version`. Leave deployment addresses out: CI
   publishes them as a release artifact.
3. Run `just codegen` and commit the changes to the justfile,
   `prt/contracts/src/Version.sol` and `CHANGELOG.md`, on a branch off `main`.
4. Open a pull request and merge it once CI passes; `check-version` runs on it
   too. The repository merges by rebase, so make sure to tag the commit that
   sits on main, and not the commit that sits on the feature branch.
5. Create a GitHub release with the new tag `v` followed by the output of
   `just print-version`, targeting that commit (pick the commit itself, since
   a branch target tags whatever its head is then), with the list of changes.
   Publishing the release creates the tag, which runs CI, which then builds
   and uploads the release artifacts.

## Test pre-release tags

If you wish to publish a test pre-release tag, you may perform the steps
above, except for the `CHANGELOG.md` edit in step 2, but instead of opening a
PR for your branch pointing to main, you may create the release targeting your
branch's head commit directly. This way, main keeps the last release version,
and CI is still able to build and publish release artifacts for the test tag.

Tip: You may name a test version so it sorts between the last release and the
one it tests: append dot-separated fields to the last release's pre-release,
such as `5.4.3-beta.2.test.1` before `5.4.3-beta.3`. Semantic versioning ranks
an identifier with letters or hyphens above any number, so `beta.2-test.1`,
`beta.test.1` or `test.1` would outrank every later numbered beta.

## Fixing a mismatch at release time

If you mistakenly create a release whose tag is different from the one
advertised by the contracts, CI will abort the release process.

If the version in the code is wrong, the developer can follow steps 1-4 and
force-push the tag to the new commit. The release follows the tag by name, and
a forced tag push triggers the CI to re-build and re-upload the release
artifacts:

```bash
git fetch origin main
git tag -f "v$(just print-version)" origin/main
git push -f origin "v$(just print-version)"
```

For a test pre-release, tag the branch's head commit instead of `origin/main`.

Meanwhile, if the tag name is wrong, the developer can delete the release and
its tag, and create a new release.
