#!/usr/bin/env bash
# Offline tests for scanner/scan_plan.sh. No Vision One key or AWS access needed:
# a local mock serves recorded-shape responses from tests/fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCAN="$ROOT/scanner/scan_plan.sh"
FIX="$HERE/fixtures"
PORT=8797
WORK="$(mktemp -d)"
MOCK_PID=""
PASS=0; FAILN=0

cleanup() { [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock <fixture-name> <expected-key>
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null
  python3 -I "$HERE/mock_api.py" "$PORT" "$FIX/$1" "$2" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
}

check() {  # check <name> <want-exit> <got-exit> <output-file> <expected-text or empty>
  local name="$1" want="$2" got="$3" out="$4" text="$5" ok=1
  [[ "$got" == "$want" ]] || ok=0
  if [[ -n "$text" ]]; then grep -q -- "$text" "$out" 2>/dev/null || ok=0; fi
  if (( ok )); then PASS=$((PASS+1)); echo "PASS  $name (exit $got)"
  else FAILN=$((FAILN+1)); echo "FAIL  $name (want exit $want, got $got${text:+, want text: $text})"; fi
}

scan() {  # scan <name> [ENV=VALUE ...] -- <scanner args...>; sets RC and OUT
  local name="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  OUT="$WORK/$name.log"
  env "${envs[@]}" VISION_ONE_BASE_URL="http://127.0.0.1:$PORT" VISION_ONE_API_KEY="${KEY:-test-key}" \
    "$SCAN" --out-dir "$WORK/$name" "$@" >"$OUT" 2>&1
  RC=$?
}

# 1. Payload is printed (step 0).
start_mock resp-compliant.json test-key
scan step0 -- --plan-json "$FIX/dummy-plan.json" --dry-run
check "step 0 prints payload (dry run)" 0 "$RC" "$OUT" "terraform-template"

# 2. Default gate is HIGH. Only MEDIUM/LOW findings -> pass.
scan default_high -- --plan-json "$FIX/dummy-plan.json"
check "default gate HIGH passes with MEDIUM/LOW only" 0 "$RC" "$OUT" "PASS"

# 3. Unaccepted HIGH finding -> fail at default gate.
start_mock resp-high.json test-key
scan high_default -- --plan-json "$FIX/dummy-plan.json"
check "HIGH finding fails at default gate" 1 "$RC" "$OUT" "EC2-088"

# 4. Gate from CLI argument.
start_mock resp-compliant.json test-key
scan cli_medium -- --plan-json "$FIX/dummy-plan.json" --fail-on MEDIUM
check "--fail-on MEDIUM fails on MEDIUM findings" 1 "$RC" "$OUT" "EC2-021"

# 5. Gate from environment variable.
scan env_medium FAIL_ON=MEDIUM -- --plan-json "$FIX/dummy-plan.json"
check "FAIL_ON=MEDIUM env fails on MEDIUM findings" 1 "$RC" "$OUT" "FAIL"

# 6. CLI overrides environment.
scan cli_over_env FAIL_ON=MEDIUM -- --plan-json "$FIX/dummy-plan.json" --fail-on HIGH
check "--fail-on HIGH overrides FAIL_ON=MEDIUM" 0 "$RC" "$OUT" "PASS"

# 7. Lowercase severity is accepted.
scan lower -- --plan-json "$FIX/dummy-plan.json" --fail-on medium
check "lowercase severity accepted" 1 "$RC" "$OUT" "FAIL"

# 8. Invalid severity -> error.
scan bad_sev -- --plan-json "$FIX/dummy-plan.json" --fail-on CRITICAL
check "invalid severity is an error" 2 "$RC" "$OUT" "Invalid severity"

# 9. Public SSH finding (MEDIUM) passes at HIGH, fails at MEDIUM.
start_mock resp-public.json test-key
scan pub_high -- --plan-json "$FIX/dummy-plan.json"
check "public SSH (MEDIUM) passes at HIGH" 0 "$RC" "$OUT" "PASS"
scan pub_medium -- --plan-json "$FIX/dummy-plan.json" --fail-on MEDIUM
check "public SSH (MEDIUM) fails at MEDIUM" 1 "$RC" "$OUT" "EC2-002"

# 10. Zero results -> error, never a pass.
start_mock resp-empty.json test-key
scan empty -- --plan-json "$FIX/dummy-plan.json"
check "zero results is an error" 2 "$RC" "$OUT" "0 scan results"

# 11. Wrong key -> API error.
start_mock resp-compliant.json test-key
KEY=wrong-key scan badkey -- --plan-json "$FIX/dummy-plan.json"
check "wrong key is an API error" 2 "$RC" "$OUT" "HTTP 401"

# 12a. Report carries the status field: summary counts and a Status column.
start_mock resp-public.json test-key
scan status_report -- --plan-json "$FIX/dummy-plan.json" --fail-on MEDIUM
check "report shows status counts" 1 "$RC" "$WORK/status_report/report.md" "status SUCCESS: 1, FAILURE: 7"
check "findings table uses resource type" 1 "$RC" "$WORK/status_report/report.md" "| FAILURE | MEDIUM | EC2-002 | aws_security_group |"
check "report lists SUCCESS results in details" 1 "$RC" "$WORK/status_report/report.md" "| SUCCESS | LOW | EC2-099 | aws_instance |"
check "report has collapsible all-results section" 1 "$RC" "$WORK/status_report/report.md" "<details>"

# 12. Missing plan file -> usage error.
scan missing -- --plan-json "$WORK/nope.json"
check "missing plan file is a usage error" 2 "$RC" "$OUT" "not found"

echo ""
echo "Offline tests: $PASS passed, $FAILN failed"
[[ $FAILN -eq 0 ]]
