#!/usr/bin/env bash

# read-portable-config.sh must point XDG_CONFIG_HOME at a caller-supplied
# config-dir so operations commands can resolve checked-in project/server
# config, and must fail closed when the layout is wrong.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="${ROOT_DIR}/fixtures/portable-subdirectory"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

run_read_config() {
  local config_dir_input="$1"
  local env_file="$2"
  local output_file="$3"
  (
    cd "${FIXTURE_DIR}"
    COMPONENT_NAME='packages/gutenberg' \
    EXTENSION_INPUT='' \
    GITHUB_WORKSPACE="${ROOT_DIR}" \
    HOMEBOY_CONFIG_DIR_INPUT="${config_dir_input}" \
    GITHUB_ENV="${env_file}" \
    GITHUB_OUTPUT="${output_file}" \
    bash "${ROOT_DIR}/scripts/setup/read-portable-config.sh"
  )
}

# ── Empty input: zero behavior change ──
run_read_config '' "${TMP_DIR}/env-empty" "${TMP_DIR}/out-empty" > /dev/null
if grep -q '^XDG_CONFIG_HOME=' "${TMP_DIR}/env-empty"; then
  echo "FAIL: empty config-dir must not set XDG_CONFIG_HOME"
  exit 1
fi
echo "PASS: empty config-dir leaves XDG_CONFIG_HOME untouched"

# ── Valid relative dir: absolute XDG_CONFIG_HOME + summary ──
log="$(run_read_config 'fixtures/config-dir' "${TMP_DIR}/env-ok" "${TMP_DIR}/out-ok")"
grep -Fxq "XDG_CONFIG_HOME=${ROOT_DIR}/fixtures/config-dir" "${TMP_DIR}/env-ok" || {
  echo "FAIL: expected absolute XDG_CONFIG_HOME in GITHUB_ENV"; cat "${TMP_DIR}/env-ok"; exit 1; }
grep -Fxq "homeboy-config-home=${ROOT_DIR}/fixtures/config-dir" "${TMP_DIR}/out-ok" || {
  echo "FAIL: expected homeboy-config-home output"; exit 1; }
printf '%s\n' "${log}" | grep -Fq 'projects: ci-fixture' || { echo "FAIL: summary must list project ids"; exit 1; }
printf '%s\n' "${log}" | grep -Fq 'servers:  ci-fixture' || { echo "FAIL: summary must list server ids"; exit 1; }
echo "PASS: valid config-dir sets XDG_CONFIG_HOME and reports projects/servers"

# ── Trailing slash is normalized ──
run_read_config 'fixtures/config-dir/' "${TMP_DIR}/env-slash" "${TMP_DIR}/out-slash" > /dev/null
grep -Fxq "XDG_CONFIG_HOME=${ROOT_DIR}/fixtures/config-dir" "${TMP_DIR}/env-slash" || {
  echo "FAIL: trailing slash must be normalized"; exit 1; }
echo "PASS: trailing slash normalized"

# ── Missing homeboy/projects: fail closed with the documented layout ──
set +e
err="$(run_read_config 'fixtures' "${TMP_DIR}/env-bad" "${TMP_DIR}/out-bad" 2>&1)"
rc=$?
set -e
[ "${rc}" -ne 0 ] || { echo "FAIL: dir without homeboy/projects must exit non-zero"; exit 1; }
printf '%s\n' "${err}" | grep -Fq 'must contain homeboy/projects/' || { echo "FAIL: missing layout error text"; printf '%s\n' "${err}"; exit 1; }
if grep -q '^XDG_CONFIG_HOME=' "${TMP_DIR}/env-bad" 2>/dev/null; then
  echo "FAIL: invalid config-dir must not set XDG_CONFIG_HOME"; exit 1
fi
echo "PASS: invalid config-dir fails closed"

echo "All config-dir checks passed."
