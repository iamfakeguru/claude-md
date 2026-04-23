#!/bin/bash
# sensory-reminder.sh
# Stop hook for UI changes.
#
# Two modes, chosen via agent-md.toml:
#
#   [visual] required = false   (default)  → advisory reminder only.
#                                            Emits additionalContext
#                                            suggesting screenshot+VLM.
#
#   [visual] required = true               → blocking. Stop is denied
#                                            unless a FRESH artifact
#                                            exists under artifacts_dir
#                                            (default .agent/visual/)
#                                            modified within
#                                            freshness_seconds (default
#                                            3600).
#
# The reminder mode is what shipped in v4 Phase 1. The blocking mode is
# new in Phase 2 and opt-in; it earns the "sensory validation" label.

. "$(dirname "$0")/_lib.sh"

INPUT=$(cat)
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

git rev-parse --is-inside-work-tree &>/dev/null || exit 0

UI_PATTERN='\.(tsx|jsx|vue|svelte|astro|css|scss|sass|html)$'
UI_CHANGED=$(
  {
    git diff --name-only 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | grep -cE "$UI_PATTERN"
)
UI_CHANGED=${UI_CHANGED:-0}

if [ "$UI_CHANGED" -eq 0 ]; then
  exit 0
fi

TOML=$(toml_path)
REQUIRED=$(read_toml "$TOML" visual required)
ART_DIR=$(read_toml "$TOML" visual artifacts_dir)
FRESH=$(read_toml "$TOML" visual freshness_seconds)
ART_DIR="${ART_DIR:-.agent/visual}"
FRESH="${FRESH:-3600}"

if [ "$REQUIRED" = "true" ]; then
  # Enforce artifact presence + freshness.
  NOW=$(date +%s)
  FRESH_COUNT=0
  if [ -d "$ART_DIR" ]; then
    # Any regular file in ART_DIR modified within FRESH seconds counts.
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      MTIME=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
      [ -z "$MTIME" ] && continue
      if [ $((NOW - MTIME)) -le "$FRESH" ]; then
        FRESH_COUNT=$((FRESH_COUNT + 1))
      fi
    done < <(find "$ART_DIR" -type f 2>/dev/null)
  fi

  if [ "$FRESH_COUNT" -eq 0 ]; then
    REASON="Visual validation required. ${UI_CHANGED} UI file(s) changed, but no artifact in ${ART_DIR} was modified within the last ${FRESH}s. Capture a screenshot (see ./skills/playwright-capture.sh), write a markdown note next to it describing what you verified, and retry."
    jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
  fi

  MSG="Visual validation: ${FRESH_COUNT} fresh artifact(s) found in ${ART_DIR}. Confirm to the user which UI diff each artifact validates."
  jq -n --arg m "$MSG" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $m}}'
  exit 0
fi

# Reminder mode (default, advisory)
MSG="UI files changed (${UI_CHANGED}). Before marking complete: (1) build and render the change, (2) capture a screenshot (see ./skills/playwright-capture.sh), (3) have it reviewed by a VLM sub-agent or the human. State the visual verification you performed. Do not self-grade. (Set [visual] required = true in agent-md.toml to turn this into a hard block.)"
jq -n --arg m "$MSG" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $m}}'
exit 0
