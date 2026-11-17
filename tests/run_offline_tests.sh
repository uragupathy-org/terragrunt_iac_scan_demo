#!/usr/bin/env bash
# Offline tests for scanner/scan_plan.sh. No Vision One key or AWS access needed:
# a local mock serves recorded-shape responses from tests/fixtures.
#
# By default each test prints the scanner's full output (step 0 payload, step 1
# findings, step 2 gate), the same output CI prints. Use --quiet for PASS/FAIL only.
#   tests/run_offline_tests.sh           verbose (default)
#   tests/run_offline_tests.sh --quiet   summary only
set -uo pipefail

VERBOSE=1
[[ "${1:-}" == "--quiet" ]] && VERBOSE=0

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCAN="$ROOT/scanner/scan_plan.sh"
FIX="$HERE/fixtures"
PORT=8797
WORK="$(mktemp -d)"
MOCK_PID=""
PASS=0; FAILN=0
OUT=""; REPORT=""; RC=0

cleanup() { [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock <fixture-name> <expected-key>
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null
  python3 -I "$HERE/mock_api.py" "$PORT" "$FIX/$1" "$2" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
}

# scan <name> [ENV=VALUE ...] -- <scanner args...>
# Runs the scanner, keeps its output in $OUT and its report in $REPORT, sets $RC.
scan() {
  local name="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  OUT="$WORK/$name.log"
  REPORT="$WORK/$name/report.md"
  env "${envs[@]}" VISION_ONE_BASE_URL="http://127.0.0.1:$PORT" VISION_ONE_API_KEY="${KEY:-test-key}" \
    "$SCAN" --out-dir "$WORK/$name" "$@" >"$OUT" 2>&1
  RC=$?
}

# check <name> <want-exit> [expected-text]
# Compares $RC with the expected exit code and checks the text in the scanner output or report.
check() {
  local name="$1" want="$2" text="${3:-}" ok=1
  [[ "$RC" == "$want" ]] || ok=0
  if [[ -n "$text" ]]; then
    local captured
    captured="$(cat "$OUT" "$REPORT" 2>/dev/null)"
    [[ "$captured" == *"$text"* ]] || ok=0   # literal substring match
  fi
  if (( ok )); then PASS=$((PASS+1)); echo "PASS  $name (exit $RC)"
  else FAILN=$((FAILN+1)); echo "FAIL  $name (want exit $want, got $RC${text:+, want text: $text})"; fi
  if (( VERBOSE )); then
    echo "----- scanner output: $name -----"
    cat "$OUT"
    echo "----- end: $name -----"
    echo ""
  fi
}

# 1. Payload is printed (step 0).
start_mock resp-compliant.json test-key
scan step0 -- --plan-json "$FIX/dummy-plan.json" --dry-run
check "step 0 prints payload (dry run)" 0 "terraform-template"

# 2. Default gate is HIGH. Only MEDIUM/LOW findings -> pass.
scan default_high -- --plan-json "$FIX/dummy-plan.json"
check "default gate HIGH passes with MEDIUM/LOW only" 0 "PASS"

# 3. Unaccepted HIGH finding -> fail at default gate.
start_mock resp-high.json test-key
scan high_default -- --plan-json "$FIX/dummy-plan.json"
check "HIGH finding fails at default gate" 1 "EC2-088"

# 4. Gate from CLI argument.
start_mock resp-compliant.json test-key
scan cli_medium -- --plan-json "$FIX/dummy-plan.json" --fail-on MEDIUM
check "--fail-on MEDIUM fails on MEDIUM findings" 1 "EC2-021"

# 5. Gate from environment variable.
scan env_medium FAIL_ON=MEDIUM -- --plan-json "$FIX/dummy-plan.json"
check "FAIL_ON=MEDIUM env fails on MEDIUM findings" 1 "FAIL"

# 6. CLI overrides environment.
scan cli_over_env FAIL_ON=MEDIUM -- --plan-json "$FIX/dummy-plan.json" --fail-on HIGH
check "--fail-on HIGH overrides FAIL_ON=MEDIUM" 0 "PASS"

# 7. Lowercase severity is accepted.
scan lower -- --plan-json "$FIX/dummy-plan.json" --fail-on medium
check "lowercase severity accepted" 1 "FAIL"

# 8. Invalid severity -> error.
scan bad_sev -- --plan-json "$FIX/dummy-plan.json" --fail-on CRITICAL
check "invalid severity is an error" 2 "Invalid severity"

# 9. Public SSH finding (MEDIUM) passes at HIGH, fails at MEDIUM.
start_mock resp-public.json test-key
scan pub_high -- --plan-json "$FIX/dummy-plan.json"
check "public SSH (MEDIUM) passes at HIGH" 0 "PASS"
scan pub_medium -- --plan-json "$FIX/dummy-plan.json" --fail-on MEDIUM
check "public SSH (MEDIUM) fails at MEDIUM" 1 "EC2-002"

# 10. Zero results -> error, never a pass.
start_mock resp-empty.json test-key
scan empty -- --plan-json "$FIX/dummy-plan.json"
check "zero results is an error" 2 "0 scan results"

# 11. Wrong key -> API error.
start_mock resp-compliant.json test-key
KEY=wrong-key scan badkey -- --plan-json "$FIX/dummy-plan.json"
check "wrong key is an API error" 2 "HTTP 401"

# 12. Report content: status counts, findings table with resourceType, all results collapsed.
start_mock resp-public.json test-key
scan status_report -- --plan-json "$FIX/dummy-plan.json" --fail-on MEDIUM
check "report shows status counts" 1 "status SUCCESS: 1, FAILURE: 7"
check "findings table uses resource type, status last" 1 "| EC2-002 | Unrestricted SSH Access | aws_security_group | MEDIUM | FAILURE |"
check "report lists SUCCESS results in details" 1 "| EC2-099 | Passing rule | aws_instance | LOW | SUCCESS |"
check "report has collapsible all-results section" 1 "<details>"

# 13. Missing plan file -> usage error.
scan missing -- --plan-json "$WORK/nope.json"
check "missing plan file is a usage error" 2 "not found"

echo ""
echo "Offline tests: $PASS passed, $FAILN failed"
[[ $FAILN -eq 0 ]]
