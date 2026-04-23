#!/bin/bash
# stop-verify.sh
# Runs when Claude tries to finish a task (Stop event).
# The agent cannot declare "Done!" until the project actually compiles,
# lints, and passes tests.
#
# Hook output contract (Claude Code):
#   exit 0 + JSON on stdout → Claude reads the structured decision.
#   We use {decision:"block", reason:...} on stdout with exit 0.
#
# Retry behavior:
#   Claude sets stop_hook_active=true on the retry after a block. We
#   still RE-RUN verification on retries — the old version short-
#   circuited, which let the agent declare "Done!" without actually
#   fixing anything. To avoid trapping the agent forever, we break out
#   after 3 consecutive failing retries (counter at
#   .agent/state/stop-verify-retries) with an advisory message.
#
# Configuration:
#   agent-md.toml [verify] typecheck / lint / test override heuristics.

. "$(dirname "$0")/_lib.sh"

INPUT=$(cat)
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

STATE_DIR=".agent/state"
RETRY_FILE="$STATE_DIR/stop-verify-retries"
mkdir -p "$STATE_DIR" 2>/dev/null

TOML=$(toml_path)
CFG_TYPECHECK=$(read_toml "$TOML" verify typecheck)
CFG_LINT=$(read_toml "$TOML" verify lint)
CFG_TEST=$(read_toml "$TOML" verify test)

ERRORS=""
CHECKS_RUN=0

run_check() {
  local label="$1" cmd="$2"
  [ -n "$cmd" ] || return 0
  CHECKS_RUN=$((CHECKS_RUN + 1))
  local OUT
  OUT=$(eval "$cmd" 2>&1)
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    ERRORS="${ERRORS}${label} FAILED:
$(echo "$OUT" | head -30)

"
  fi
}

# --- Typecheck ---
if [ -n "$CFG_TYPECHECK" ]; then
  run_check "TYPECHECK ($CFG_TYPECHECK)" "$CFG_TYPECHECK"
elif [ -f "tsconfig.json" ]; then
  run_check "TSC --noEmit" "npx tsc --noEmit"
fi

# --- Lint ---
if [ -n "$CFG_LINT" ]; then
  run_check "LINT ($CFG_LINT)" "$CFG_LINT"
else
  if ls .eslintrc* eslint.config.* 2>/dev/null | grep -q .; then
    run_check "ESLINT" "npx eslint . --quiet"
  fi
  if command -v ruff &>/dev/null && [ -n "$(ls *.py 2>/dev/null)" ]; then
    run_check "RUFF" "ruff check ."
  fi
fi

# --- Python mypy (still heuristic — not covered by a single CFG slot) ---
if [ -z "$CFG_TYPECHECK" ] && command -v mypy &>/dev/null \
   && { [ -f "mypy.ini" ] || grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; }; then
  run_check "MYPY" "mypy ."
fi

# --- Rust ---
if [ -z "$CFG_TYPECHECK" ] && [ -f "Cargo.toml" ]; then
  run_check "CARGO CHECK" "cargo check"
fi

# --- Tests ---
if [ -n "$CFG_TEST" ]; then
  run_check "TESTS ($CFG_TEST)" "$CFG_TEST"
elif [ -f "package.json" ]; then
  HAS_TEST=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  if [ -n "$HAS_TEST" ] && [ "$HAS_TEST" != "echo \"Error: no test specified\" && exit 1" ]; then
    run_check "NPM TEST" "npm test --silent"
  fi
elif { [ -f "pytest.ini" ] || [ -f "pyproject.toml" ]; } && command -v pytest &>/dev/null; then
  run_check "PYTEST" "pytest --tb=short -q"
elif [ -f "Cargo.toml" ]; then
  run_check "CARGO TEST" "cargo test"
fi

# --- Report ---
if [ -n "$ERRORS" ]; then
  COUNT=1
  if [ -f "$RETRY_FILE" ]; then COUNT=$(( $(cat "$RETRY_FILE") + 1 )); fi
  echo "$COUNT" > "$RETRY_FILE"

  if [ "$COUNT" -ge 3 ] && [ "$STOP_ACTIVE" = "true" ]; then
    # Loop-break: emit advisory, let the Stop through, clear counter.
    rm -f "$RETRY_FILE"
    MSG="stop-verify: 3 consecutive failed retries. Releasing the Stop to avoid an infinite loop. The last error was:

$ERRORS

The failing verification command still needs to be fixed. Tell the user."
    jq -n --arg m "$MSG" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $m}}'
    exit 0
  fi

  SUMMARY=$(printf 'Verification failed (%d checks ran). Fix these errors before completing:\n\n%s' \
    "$CHECKS_RUN" "$ERRORS")
  jq -n --arg r "$SUMMARY" '{decision: "block", reason: $r}'
  exit 0
fi

# Clean pass: clear retry counter.
rm -f "$RETRY_FILE"

if [ "$CHECKS_RUN" -eq 0 ]; then
  jq -n '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: "No type-checker, linter, or test suite detected. Task completion is unverified. State this to the user, or add an agent-md.toml to declare verification commands."}}'
  exit 0
fi

exit 0
