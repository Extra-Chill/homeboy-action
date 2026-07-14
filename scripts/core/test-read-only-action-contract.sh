#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${ROOT}/action.yml"
WORKFLOW="${ROOT}/.github/workflows/ci.yml"
RESOLVER="${ROOT}/scripts/core/resolve-commands.sh"
RUNNER="${ROOT}/scripts/core/run-homeboy-commands.sh"

assert_absent() {
  local pattern="$1" file="$2" label="$3"
  if grep -Eq -- "${pattern}" "${file}"; then
    printf 'FAIL: %s\n' "${label}" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "${label}"
}

assert_absent 'autofix|ci/autofix|scripts/autofix' "${ACTION}" 'action has no autofix API or execution route'
assert_absent 'autofix|ci/autofix' "${WORKFLOW}" 'reusable workflow has no autofix inputs or forwarding'
assert_absent 'git (commit|push)|gh pr (create|edit)|--write' "${RUNNER}" 'quality runner has no source-mutation or PR route'

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

set +e
GITHUB_OUTPUT="${tmpdir}/output" \
  GITHUB_ENV="${tmpdir}/env" \
  COMMANDS_INPUT='refactor --from all --write' \
  SCOPE_CONTEXT='manual' \
  bash "${RESOLVER}" >"${tmpdir}/resolver.log" 2>&1
status=$?
set -e

if [ "${status}" -eq 0 ]; then
  printf 'FAIL: resolver accepts source-mutating --write command\n' >&2
  exit 1
fi
grep -F -- 'Source-mutating --write and --fix commands are not supported' "${tmpdir}/resolver.log" >/dev/null
printf 'PASS: resolver rejects explicit source mutation\n'

set +e
GITHUB_OUTPUT="${tmpdir}/fix-output" \
  GITHUB_ENV="${tmpdir}/fix-env" \
  COMMANDS_INPUT='review lint --fix=true' \
  SCOPE_CONTEXT='manual' \
  bash "${RESOLVER}" >"${tmpdir}/fix.log" 2>&1
status=$?
set -e

if [ "${status}" -eq 0 ]; then
  printf 'FAIL: resolver accepts explicit fixer command\n' >&2
  exit 1
fi
grep -F -- 'Source-mutating --write and --fix commands are not supported' "${tmpdir}/fix.log" >/dev/null
printf 'PASS: resolver rejects explicit fixer command\n'

printf 'Read-only action contract checks passed.\n'
