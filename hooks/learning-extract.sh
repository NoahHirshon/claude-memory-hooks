#!/usr/bin/env bash
# learning-extract.sh — Stop hook entry point
# Parses session transcript for corrections/confirmations, saves as memory files
# Stdin: JSON with transcript_path, cwd, session_id
# Stdout: JSON with decision (always "approve" — extraction is a side effect)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_ROOT/scripts"
CONFIG="$PLUGIN_ROOT/config.json"

# Always approve — we never block session end
approve_and_exit() {
  echo '{"decision": "approve"}'
  exit 0
}

# --- Read stdin ---
INPUT=$(cat)

# --- Check config ---
if [[ ! -f "$CONFIG" ]]; then
  approve_and_exit
fi

# Check if learning is enabled
if command -v jq &>/dev/null; then
  LEARNING_ENABLED=$(jq -r '.learningEnabled // true' "$CONFIG")
else
  LEARNING_ENABLED=$(grep -o '"learningEnabled":true' "$CONFIG" && echo "true" || echo "false")
fi

if [[ "$LEARNING_ENABLED" != "true" ]]; then
  approve_and_exit
fi

# --- Extract fields ---
if command -v jq &>/dev/null; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
else
  TRANSCRIPT_PATH=$(echo "$INPUT" | grep -o '"transcript_path":"[^"]*"' | sed 's/"transcript_path":"//;s/"$//' || true)
  CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | sed 's/"cwd":"//;s/"$//' || true)
fi

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  approve_and_exit
fi

# --- Resolve output directory ---
# Prefer project-scoped memory, fall back to first configured dir
HOME_DIR="$HOME"
OUTPUT_DIR=""

if [[ -n "$CWD" ]]; then
  PROJECT_KEY=$(echo "$CWD" | sed 's|/|-|g')
  PROJECT_MEMORY="$HOME_DIR/.claude/projects/$PROJECT_KEY/memory"
  if [[ -d "$PROJECT_MEMORY" ]]; then
    OUTPUT_DIR="$PROJECT_MEMORY"
  fi
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  # Fall back to first memoryDir from config
  if command -v jq &>/dev/null; then
    FIRST_DIR=$(jq -r '.memoryDirs[0] // ""' "$CONFIG")
  else
    FIRST_DIR=$(grep -o '"~[^"]*"' "$CONFIG" | head -1 | tr -d '"' || true)
  fi
  OUTPUT_DIR="${FIRST_DIR/#\~/$HOME_DIR}"
fi

if [[ -z "$OUTPUT_DIR" ]] || [[ ! -d "$OUTPUT_DIR" ]]; then
  approve_and_exit
fi

# --- Run extraction ---
CREATED=$(bash "$SCRIPTS/extract-learnings.sh" "$TRANSCRIPT_PATH" "$OUTPUT_DIR" 2>/dev/null || true)

if [[ -n "$CREATED" ]]; then
  COUNT=$(echo "$CREATED" | wc -l | tr -d ' ')
  echo "claude-memory-hooks: Extracted $COUNT learning(s) from this session" >&2
fi

approve_and_exit
