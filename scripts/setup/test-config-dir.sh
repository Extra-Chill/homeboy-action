#!/usr/bin/env bash

# read-portable-config.sh must materialize a caller-supplied config-dir into
# Homeboy's config root ($HOME/.config/homeboy — XDG_CONFIG_HOME is not
# honored by Homeboy) so operations commands can resolve checked-in
# project/server config, must fail closed on a wrong layout, and must never
# overwrite config a runner already has.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="${ROOT_DIR}/fixtures/portable-subdirectory"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

run_read_config() {
  local config_dir_input="$1"
  local config_root="$2"
  local env_file="$3"
  local output_file="$4"
  (
    cd "${FIXTURE_DIR}"
    COMPONENT_NAME='packages/gutenberg' \
    EXTENSION_INPUT='' \
    GITHUB_WORKSPACE="${ROOT_DIR}" \
    HOMEBOY_CONFIG_DIR_INPUT="${config_dir_input}" \
    HOMEBOY_CONFIG_ROOT_OVERRIDE="${config_root}" \
    GITHUB_ENV="${env_file}" \
    GITHUB_OUTPUT="${output_file}" \
    bash "${ROOT_DIR}/scripts/setup/read-portable-config.sh"
  )
}

# ── Empty input: zero behavior change ──
run_read_config '' "${TMP_DIR}/root-empty" "${TMP_DIR}/env-empty" "${TMP_DIR}/out-empty" > /dev/null
[ ! -e "${TMP_DIR}/root-empty" ] || { echo "FAIL: empty config-dir must not create a config root"; exit 1; }
echo "PASS: empty config-dir is a no-op"

# ── Valid relative dir: materialized into the config root + summary ──
log="$(run_read_config 'fixtures/config-dir' "${TMP_DIR}/root-ok" "${TMP_DIR}/env-ok" "${TMP_DIR}/out-ok")"
[ -f "${TMP_DIR}/root-ok/projects/ci-fixture/ci-fixture.json" ] || { echo "FAIL: project not materialized"; exit 1; }
[ -f "${TMP_DIR}/root-ok/servers/ci-fixture.json" ] || { echo "FAIL: server not materialized"; exit 1; }
grep -Fxq "homeboy-config-root=${TMP_DIR}/root-ok" "${TMP_DIR}/out-ok" || { echo "FAIL: expected homeboy-config-root output"; exit 1; }
printf '%s\n' "${log}" | grep -Fq 'projects: ci-fixture' || { echo "FAIL: summary must list project ids"; exit 1; }
printf '%s\n' "${log}" | grep -Fq 'servers:  ci-fixture' || { echo "FAIL: summary must list server ids"; exit 1; }
if grep -q 'XDG_CONFIG_HOME' "${TMP_DIR}/env-ok" 2>/dev/null; then
  echo "FAIL: must not export XDG_CONFIG_HOME (Homeboy does not honor it)"; exit 1
fi
echo "PASS: valid config-dir materializes projects/servers into the config root"

# ── Trailing slash is normalized ──
run_read_config 'fixtures/config-dir/' "${TMP_DIR}/root-slash" "${TMP_DIR}/env-slash" "${TMP_DIR}/out-slash" > /dev/null
[ -f "${TMP_DIR}/root-slash/projects/ci-fixture/ci-fixture.json" ] || { echo "FAIL: trailing slash must be normalized"; exit 1; }
echo "PASS: trailing slash normalized"

# ── Missing homeboy/projects: fail closed with the documented layout ──
set +e
err="$(run_read_config 'fixtures' "${TMP_DIR}/root-bad" "${TMP_DIR}/env-bad" "${TMP_DIR}/out-bad" 2>&1)"
rc=$?
set -e
[ "${rc}" -ne 0 ] || { echo "FAIL: dir without homeboy/projects must exit non-zero"; exit 1; }
printf '%s\n' "${err}" | grep -Fq 'must contain homeboy/projects/' || { echo "FAIL: missing layout error text"; printf '%s\n' "${err}"; exit 1; }
[ ! -e "${TMP_DIR}/root-bad/projects" ] || { echo "FAIL: invalid config-dir must not materialize anything"; exit 1; }
echo "PASS: invalid config-dir fails closed"

# ── Existing runner config is never overwritten ──
mkdir -p "${TMP_DIR}/root-busy/projects/real-project"
echo '{"id":"real-project"}' > "${TMP_DIR}/root-busy/projects/real-project/real-project.json"
set +e
err="$(run_read_config 'fixtures/config-dir' "${TMP_DIR}/root-busy" "${TMP_DIR}/env-busy" "${TMP_DIR}/out-busy" 2>&1)"
rc=$?
set -e
[ "${rc}" -ne 0 ] || { echo "FAIL: must refuse to overwrite an existing config root"; exit 1; }
printf '%s\n' "${err}" | grep -Fq 'refuses to overwrite existing' || { echo "FAIL: missing overwrite refusal text"; exit 1; }
[ -f "${TMP_DIR}/root-busy/projects/real-project/real-project.json" ] || { echo "FAIL: existing config was clobbered"; exit 1; }
[ ! -e "${TMP_DIR}/root-busy/projects/ci-fixture" ] || { echo "FAIL: fixture must not be merged into an occupied root"; exit 1; }
echo "PASS: existing runner config is preserved"

echo "All config-dir checks passed."
