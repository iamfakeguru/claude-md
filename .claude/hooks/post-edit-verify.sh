#!/bin/bash
# post-edit-verify.sh
# Runs after every Write/Edit/MultiEdit. Surfaces lint failures so the
# agent sees them immediately. Type-checking runs only at Stop (via
# stop-verify.sh) to avoid 10-30s tsc delays on every single edit.
#
# Hook output contract (Claude Code):
#   exit 0 + JSON on stdout  → Claude reads the structured decision.
# We emit {decision: "block", reason: ...} so Claude sees the errors.
#
# Note: this is a PostToolUse hook, so the edit already landed on disk.
# The "block" decision stops Claude from progressing until the lint
# errors are addressed; it does not unwind the write.
#
# Configuration:
#   agent-md.toml [verify] lint_file = "npx eslint --quiet {file}"
#   {file} is substituted with the edited file path.

. "$(dirname "$0")/_lib.sh"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only check code files we know how to lint per-file
if ! echo "$FILE_PATH" | grep -qE '\.(ts|tsx|js|jsx|py|rs)$'; then
  exit 0
fi

TOML=$(toml_path)
CFG_LINT_FILE=$(read_toml "$TOML" verify lint_file)

ERRORS=""

if [ -n "$CFG_LINT_FILE" ]; then
  # Substitute {file} so the file path goes through the shell as a
  # quoted env var, not via literal string splicing.
  export AGENT_MD_FILE="$FILE_PATH"
  OUT=$(bash -c "${CFG_LINT_FILE//\{file\}/\"\$AGENT_MD_FILE\"}" 2>&1)
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    ERRORS="lint errors in ${FILE_PATH}:
${OUT}"
  fi
else
  # Heuristic fallback
  if echo "$FILE_PATH" | grep -qE '\.(ts|tsx|js|jsx)$' \
     && ls .eslintrc* eslint.config.* 2>/dev/null | grep -q .; then
    OUT=$(npx eslint --quiet "$FILE_PATH" 2>&1)
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
      ERRORS="eslint errors in ${FILE_PATH}:
${OUT}"
    fi
  fi

  if echo "$FILE_PATH" | grep -qE '\.py$' && command -v ruff &>/dev/null; then
    OUT=$(ruff check "$FILE_PATH" 2>&1)
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
      ERRORS="${ERRORS}
ruff errors in ${FILE_PATH}:
${OUT}"
    fi
  fi
fi

if [ -n "$ERRORS" ]; then
  TRUNCATED=$(printf '%s' "$ERRORS" | head -50)
  REASON="Lint failed. Fix before continuing:
${TRUNCATED}"
  jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
  exit 0
fi

exit 0
