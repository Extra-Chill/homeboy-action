#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/scripts/core/lib.sh"

assert_status() {
  local expected="$1"
  local label="$2"
  shift 2

  set +e
  "$@"
  local actual="$?"
  set -e

  if [ "${actual}" != "${expected}" ]; then
    printf 'FAIL: %s\nexpected status: %s\nactual status:   %s\n' "${label}" "${expected}" "${actual}"
    exit 1
  fi

  printf 'PASS: %s\n' "${label}"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  case "${haystack}" in
    *"${needle}"*) printf 'PASS: %s\n' "${label}" ;;
    *)
      printf 'FAIL: %s\nexpected to contain: %s\nactual: %s\n' "${label}" "${needle}" "${haystack}"
      exit 1
      ;;
  esac
}

setup_repo() {
  TEST_DIR="$(mktemp -d)"
  git -C "${TEST_DIR}" init --quiet
  git -C "${TEST_DIR}" config user.email test@example.com
  git -C "${TEST_DIR}" config user.name Test
  mkdir -p "${TEST_DIR}/src"
  printf '%s\n' '<?php' '$a = 1;' > "${TEST_DIR}/src/a.php"
  printf '%s\n' '<?php' '$b = 1;' > "${TEST_DIR}/src/b.php"
  git -C "${TEST_DIR}" add .
  git -C "${TEST_DIR}" commit --quiet -m initial
  cd "${TEST_DIR}"
}

setup_repo
AUTOFIX_REPORT=$'lint_autofix\t1\tsrc/a.php'
printf '%s\n' '<?php' '$a = 2;' >> src/a.php
git add src/a.php
assert_status 0 "small reported diff is safe" autofix_diff_safety_status

git reset --hard --quiet HEAD
AUTOFIX_REPORT=$'lint_autofix\t1\tsrc/a.php'
for n in $(seq 1 60); do
  printf '$a%s = %s;\n' "${n}" "${n}"
done >> src/a.php
git add src/a.php
line_status="$(autofix_diff_safety_status || true)"
assert_contains "${line_status}" "too-many-lines" "large one-fix diff is blocked"

git reset --hard --quiet HEAD
AUTOFIX_REPORT=$'lint_autofix\t1\tsrc/a.php'
for file in a b c d; do
  printf '%s\n' '<?php' '$x = 1;' > "src/${file}.php"
  git add "src/${file}.php"
done
file_status="$(autofix_diff_safety_status || true)"
assert_contains "${file_status}" "too-many-files" "many files for one fix are blocked"

git reset --hard --quiet HEAD
AUTOFIX_REPORT=""
AUTOFIX_CHANGED_FILES=$'homeboy.json\nsrc/a.php\nsrc/b.php'
printf '%s\n' '{"id":"fixture"}' > homeboy.json
printf '%s\n' '<?php' '$a = 3;' > src/a.php
printf '%s\n' '<?php' '$b = 3;' > src/b.php
report="$(autofix_synthesize_source_report "${TEST_DIR}")"
assert_contains "${report}" $'source_change\t2\t' "fallback report counts reviewable source files"
assert_contains "${report}" "src/a.php" "fallback report includes first source file"
assert_contains "${report}" "src/b.php" "fallback report includes second source file"

printf 'All autofix diff safety checks passed.\n'
