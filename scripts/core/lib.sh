#!/usr/bin/env bash

set -euo pipefail

# Source scope module for flag generation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scope/flags.sh"

# Check whether the current PR is still open.
# Returns 0 (true) if the PR is open, 1 (false) if merged/closed/unknown.
# Uses gh CLI when available, falls back to GitHub REST API via curl.
# Requires: GITHUB_REPOSITORY and PR_NUMBER (or $1) in the environment.
pr_is_active() {
  local pr_number="${1:-${PR_NUMBER:-}}"
  local repo="${GITHUB_REPOSITORY:-}"

  if [ -z "${pr_number}" ] || [ -z "${repo}" ]; then
    # Can't check — assume active to avoid false cancellations
    return 0
  fi

  local state=""
  if command -v gh >/dev/null 2>&1; then
    state=$(gh pr view "${pr_number}" --repo "${repo}" --json state -q '.state' 2>/dev/null || true)
  fi

  if [ -z "${state}" ]; then
    # Fallback to curl — use GH_TOKEN or GITHUB_TOKEN for auth
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -n "${token}" ]; then
      state=$(curl -sfL \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/pulls/${pr_number}" 2>/dev/null \
        | jq -r '.state // empty' 2>/dev/null || true)
    fi
  fi

  case "${state}" in
    OPEN|open)
      return 0
      ;;
    MERGED|CLOSED|merged|closed)
      return 1
      ;;
    *)
      # Unknown state — assume active to avoid false cancellations
      return 0
      ;;
  esac
}

resolve_component_id() {
  if [ -n "${COMPONENT_NAME:-}" ]; then
    printf '%s\n' "${COMPONENT_NAME}"
  elif [ -n "${component_id:-}" ]; then
    printf '%s\n' "${component_id}"
  elif [ -f "homeboy.json" ]; then
    local from_portable
    from_portable="$(jq -r '.id // empty' homeboy.json 2>/dev/null || true)"
    if [ -n "${from_portable}" ]; then
      printf '%s\n' "${from_portable}"
    else
      basename "${GITHUB_REPOSITORY}"
    fi
  else
    basename "${GITHUB_REPOSITORY}"
  fi
}

resolve_workspace() {
  # When running in a multi-component repo, COMPONENT_DIR points to the
  # subdirectory containing the component's homeboy.json. Homeboy core
  # uses --path to read config and scope operations to this directory.
  local component_dir="${COMPONENT_DIR:-}"
  if [ -n "${component_dir}" ] && [ "${component_dir}" != "." ]; then
    printf '%s/%s\n' "$(pwd)" "${component_dir}"
  else
    printf '%s\n' "$(pwd)"
  fi
}

quality_base_command() {
  local cmd="$1"
  cmd="$(printf '%s' "${cmd}" | xargs)"
  case "${cmd}" in
    "review audit"*) printf '%s\n' "audit" ;;
    "review audit-baseline"*) printf '%s\n' "audit-baseline" ;;
    "review lint"*) printf '%s\n' "lint" ;;
    "review test"*) printf '%s\n' "test" ;;
    "review build"*) printf '%s\n' "build" ;;
    "review ci"*) printf '%s\n' "ci" ;;
    audit|audit\ *) printf '%s\n' "audit" ;;
    audit-baseline|audit-baseline\ *) printf '%s\n' "audit-baseline" ;;
    lint|lint\ *) printf '%s\n' "lint" ;;
    test|test\ *) printf '%s\n' "test" ;;
    build|build\ *) printf '%s\n' "build" ;;
    ci|ci\ *) printf '%s\n' "ci" ;;
    *) printf '%s\n' "$(printf '%s' "${cmd}" | awk '{print $1}')" ;;
  esac
}

# Sort commands into canonical order: audit → lint → test → build → refactor → bench.
# Review-backed audit/lint/test/build are core quality gates; real refactor and bench commands
# run after them when explicitly requested. Release and operations commands are
# handled by dedicated steps and are filtered out here defensively.
canonicalize_commands() {
  local commands="$1"
  local audit="" lint="" test="" build="" refactor="" bench="" others=()
  local cmd base_cmd

  IFS=',' read -ra CMD_ARRAY <<< "${commands}"
  for cmd in "${CMD_ARRAY[@]}"; do
    cmd="$(printf '%s' "${cmd}" | xargs)"
    base_cmd="$(quality_base_command "${cmd}")"
    case "${base_cmd}" in
      audit)   audit="${cmd}" ;;
      lint)    lint="${cmd}" ;;
      test)    test="${cmd}" ;;
      build)   build="${cmd}" ;;
      refactor) refactor="${cmd}" ;;
      bench) bench="${cmd}" ;;
      release|fleet|deploy) ;;
      *)       others+=("${cmd}") ;;
    esac
  done

  local result=()
  [ -n "${audit}" ] && result+=("${audit}")
  [ -n "${lint}" ]  && result+=("${lint}")
  [ -n "${test}" ]  && result+=("${test}")
  [ -n "${build}" ] && result+=("${build}")
  [ -n "${refactor}" ] && result+=("${refactor}")
  [ -n "${bench}" ] && result+=("${bench}")
  result+=("${others[@]+"${others[@]}"}")

  local IFS=','
  printf '%s\n' "${result[*]}"
}

has_lint_command() {
  local commands="$1"
  local cmd
  IFS=',' read -ra CMD_ARRAY <<< "${commands}"

  for cmd in "${CMD_ARRAY[@]}"; do
    if [ "$(quality_base_command "${cmd}")" = "lint" ]; then
      printf '%s\n' "true"
      return 0
    fi
  done

  printf '%s\n' "false"
}

resolve_baseline_commands() {
  local requested_commands="$1"
  local baseline_input="${2:-auto}"
  local source_commands cmd base_cmd requested_cmd requested_base found found_cmd result=()

  baseline_input="$(printf '%s' "${baseline_input}" | xargs)"
  case "${baseline_input}" in
    ""|auto)
      source_commands="${requested_commands}"
      ;;
    none|false|off)
      printf '\n'
      return 0
      ;;
    *)
      source_commands="${baseline_input}"
      ;;
  esac

  IFS=',' read -ra CMD_ARRAY <<< "$(canonicalize_commands "${source_commands}")"
  for cmd in "${CMD_ARRAY[@]}"; do
    cmd="$(echo "${cmd}" | xargs)"
    base_cmd="$(quality_base_command "${cmd}")"
    case "${base_cmd}" in
      audit|lint|test) ;;
      *) continue ;;
    esac

    found=false
    found_cmd=""
    IFS=',' read -ra REQUESTED_ARRAY <<< "${requested_commands}"
    for requested_cmd in "${REQUESTED_ARRAY[@]}"; do
      requested_cmd="$(echo "${requested_cmd}" | xargs)"
      requested_base="$(quality_base_command "${requested_cmd}")"
      if [ "${requested_base}" = "${base_cmd}" ]; then
        found=true
        found_cmd="${requested_cmd}"
        break
      fi
    done

    if [ "${found}" = true ]; then
      result+=("${found_cmd}")
    fi
  done

  local IFS=','
  printf '%s\n' "${result[*]}"
}

settings_json_flags() {
  local raw="${HOMEBOY_SETTINGS_JSON:-}"
  if [ -z "${raw}" ] || [ "${raw}" = "{}" ]; then
    return 0
  fi

  if ! printf '%s' "${raw}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::HOMEBOY_SETTINGS_JSON must be a JSON object; ignoring settings override"
    return 0
  fi

  local key
  local value
  local flag_value
  while IFS=$'\t' read -r key value; do
    [ -n "${key}" ] || continue
    flag_value="${key}=${value}"
    printf ' --setting-json %q' "${flag_value}"
  done < <(printf '%s' "${raw}" | jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv')
}

review_subcommand_run_command() {
  local cmd="$1"
  local component_id="$2"
  local workspace="$3"
  local global_flags="$4"
  local review_cmd base_cmd rest

  review_cmd="${cmd#review }"
  base_cmd="$(printf '%s' "${review_cmd}" | awk '{print $1}')"
  rest="$(printf '%s' "${review_cmd#${base_cmd}}" | xargs)"

  if [ -n "${rest}" ]; then
    printf 'homeboy %sreview %s %s %s --path %s\n' "${global_flags}" "${base_cmd}" "${component_id}" "${rest}" "${workspace}"
  else
    printf 'homeboy %sreview %s %s --path %s\n' "${global_flags}" "${base_cmd}" "${component_id}" "${workspace}"
  fi
}

homeboy_global_flags() {
  local output_file="${1:-}"
  local flags=""

  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    if homeboy_supports_placement; then
      flags="${flags}--placement local "
    else
      flags="${flags}--force-hot --allow-local-hot "
    fi
  fi

  # --output is a global flag and must appear before the subcommand
  # (clap global args don't propagate when placed after positional args)
  if [ -n "${output_file}" ]; then
    flags="${flags}--output ${output_file} "
  fi

  printf '%s' "${flags}"
}

# The action preflights this after selecting the binary. Keep this fallback for
# direct script consumers and cache the probe within a shell process.
homeboy_supports_placement() {
  if [ -z "${HOMEBOY_ACTION_SUPPORTS_PLACEMENT+x}" ]; then
    if homeboy --help 2>&1 | grep -E '^[[:space:]]+--placement([[:space:]]|<)' >/dev/null; then
      HOMEBOY_ACTION_SUPPORTS_PLACEMENT=true
    else
      HOMEBOY_ACTION_SUPPORTS_PLACEMENT=false
    fi
  fi

  [ "${HOMEBOY_ACTION_SUPPORTS_PLACEMENT}" = "true" ]
}

build_run_command() {
  local cmd
  cmd="$(printf '%s' "$1" | xargs)"
  local component_id="$2"
  local workspace="$3"
  local output_file="${4:-}"
  local full_cmd
  local global_flags
  global_flags="$(homeboy_global_flags "${output_file}")"

  if [[ "${cmd}" == refactor* ]]; then
    full_cmd="homeboy ${global_flags}refactor ${component_id} ${cmd#refactor } --path ${workspace}"
  elif [[ "${cmd}" == bench* ]]; then
    local bench_args
    bench_args="$(printf '%s' "${cmd#bench}" | xargs)"
    full_cmd="homeboy ${global_flags}bench ${component_id}"
    [ -n "${bench_args}" ] && full_cmd="${full_cmd} ${bench_args}"
    full_cmd="${full_cmd} --path ${workspace}"
  elif [[ "${cmd}" == "review ci"* ]]; then
    full_cmd="homeboy ${global_flags}${cmd}"
  elif [[ "${cmd}" == "review "* ]]; then
    full_cmd="$(review_subcommand_run_command "${cmd}" "${component_id}" "${workspace}" "${global_flags}")"
  elif [[ "$(quality_base_command "${cmd}")" =~ ^(audit|audit-baseline|lint|test|build)$ ]]; then
    full_cmd="$(review_subcommand_run_command "review ${cmd}" "${component_id}" "${workspace}" "${global_flags}")"
  else
    full_cmd="homeboy ${global_flags}${cmd} ${component_id} --path ${workspace}"
  fi

  local scope
  scope="$(scope_flags_for "${cmd}")"
  [ -n "${scope}" ] && full_cmd="${full_cmd} ${scope}"

  if [ -n "${EXTRA_ARGS:-}" ]; then
    full_cmd="${full_cmd} ${EXTRA_ARGS}"
  fi

  if [[ "${cmd}" == bench* ]]; then
    if [ -n "${BENCH_RIG:-}" ]; then
      full_cmd="${full_cmd} --rig ${BENCH_RIG}"
    fi
    if [ -n "${BENCH_SCENARIO:-}" ]; then
      full_cmd="${full_cmd} --scenario ${BENCH_SCENARIO}"
    fi
    if [ -n "${BENCH_RUNS:-}" ]; then
      full_cmd="${full_cmd} --runs ${BENCH_RUNS}"
    fi
    if [ -n "${BENCH_ITERATIONS:-}" ]; then
      full_cmd="${full_cmd} --iterations ${BENCH_ITERATIONS}"
    fi
    if [ -n "${BENCH_REGRESSION_THRESHOLD:-}" ]; then
      full_cmd="${full_cmd} --regression-threshold ${BENCH_REGRESSION_THRESHOLD}"
    fi
    full_cmd="${full_cmd}$(settings_json_flags)"
  fi

  printf '%s\n' "${full_cmd}"
}

build_review_report_command() {
  local component_id="$1"
  local workspace="$2"
  local full_cmd
  local global_flags

  global_flags="$(homeboy_global_flags)"

  full_cmd="homeboy ${global_flags}review ${component_id} --path ${workspace} --report=pr-comment"

  local scope
  scope="$(scope_flags_for "review")"
  [ -n "${scope}" ] && full_cmd="${full_cmd} ${scope}"

  printf '%s\n' "${full_cmd}"
}

build_observation_export_command() {
  local since_window="$1"
  local output_dir="$2"

  printf 'homeboy runs export --since %s --output %s\n' "${since_window}" "${output_dir}"
}

build_observation_import_command() {
  local import_dir="$1"

  printf 'homeboy runs import %s\n' "${import_dir}"
}

command_output_stem() {
  local cmd="$1"
  local stem
  stem="$(printf '%s' "${cmd}" | sed -E 's/[^[:alnum:]._-]+/-/g; s/^-+//; s/-+$//')"
  stem="${stem#-}"
  stem="${stem%-}"
  if [ -z "${stem}" ]; then
    stem="homeboy-output"
  fi
  printf '%s\n' "${stem}"
}
