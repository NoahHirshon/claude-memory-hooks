#!/usr/bin/env bash
# memory-inject.sh — UserPromptSubmit hook
# Reads user prompt, matches against memory files, injects relevant context
# Stdin: JSON with user_prompt, cwd, session_id
# Stdout: JSON with hookSpecificOutput.additionalContext (or empty for no injection)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_ROOT/scripts"
CONFIG="$PLUGIN_ROOT/config.json"

# --- Read stdin ---
INPUT=$(cat)

# --- Extract fields (jq preferred, grep fallback) ---
if command -v jq &>/dev/null; then
  PROMPT=$(echo "$INPUT" | jq -r '.prompt // .user_prompt // ""')
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
else
  PROMPT=$(echo "$INPUT" | grep -o '"prompt":"[^"]*"' | sed 's/"prompt":"//;s/"$//' || true)
  CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | sed 's/"cwd":"//;s/"$//' || true)
fi

# Normalize whitespace (newlines, tabs → spaces) for keyword matching
PROMPT=$(printf '%s' "$PROMPT" | tr '\n\r\t' '   ')

# Skip empty or very short prompts
if [[ ${#PROMPT} -lt 5 ]]; then
  exit 0
fi

# --- Load config ---
if [[ ! -f "$CONFIG" ]]; then
  # First run — copy from example config
  EXAMPLE="$PLUGIN_ROOT/config.example.json"
  if [[ -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$CONFIG"
  else
    cat > "$CONFIG" << 'DEFAULTCONFIG'
{
  "memoryDirs": ["~/.claude/memory"],
  "maxInjections": 50,
  "relevanceThreshold": 0.25,
  "learningEnabled": true,
  "debugMode": false
}
DEFAULTCONFIG
  fi
  echo "claude-memory-hooks: Created config at $CONFIG — edit memoryDirs to point at your memory files." >&2
  exit 0
fi

# Parse config (jq preferred, grep fallback)
if command -v jq &>/dev/null; then
  MAX_INJECTIONS=$(jq -r '.maxInjections // 3' "$CONFIG")
  THRESHOLD=$(jq -r '.relevanceThreshold // 0.25' "$CONFIG")
  DEBUG=$(jq -r '.debugMode // false' "$CONFIG")
  MEMORY_DIRS_RAW=$(jq -r '.memoryDirs[]' "$CONFIG" 2>/dev/null || true)
else
  MAX_INJECTIONS=$(grep -o '"maxInjections":[0-9]*' "$CONFIG" | grep -o '[0-9]*' || echo "3")
  THRESHOLD=$(grep -o '"relevanceThreshold":[0-9.]*' "$CONFIG" | grep -o '[0-9.]*' || echo "0.25")
  DEBUG="false"
  MEMORY_DIRS_RAW=$(grep -o '"~[^"]*"' "$CONFIG" | tr -d '"' || true)
fi

# --- Resolve memory directories ---
RESOLVED_DIRS=""
HOME_DIR="$HOME"

while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  # Expand ~ to home directory
  expanded="${dir/#\~/$HOME_DIR}"
  if [[ -d "$expanded" ]]; then
    RESOLVED_DIRS="$RESOLVED_DIRS $expanded"
  fi
done <<< "$MEMORY_DIRS_RAW"

# Auto-discover project-scoped memory from cwd
if [[ -n "$CWD" ]]; then
  PROJECT_KEY=$(echo "$CWD" | sed 's|/|-|g')
  PROJECT_MEMORY="$HOME_DIR/.claude/projects/$PROJECT_KEY/memory"
  if [[ -d "$PROJECT_MEMORY" ]]; then
    RESOLVED_DIRS="$RESOLVED_DIRS $PROJECT_MEMORY"
  fi
fi

# Deduplicate directories (auto-discovery may overlap with config)
RESOLVED_DIRS=$(echo "$RESOLVED_DIRS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

# No memory directories found — nothing to inject
if [[ -z "${RESOLVED_DIRS// /}" ]]; then
  [[ "$DEBUG" == "true" ]] && echo "claude-memory-hooks: No memory directories found" >&2
  exit 0
fi

# --- Build/refresh cache ---
CACHE_FILE=$(bash "$SCRIPTS/build-cache.sh" $RESOLVED_DIRS 2>/dev/null || true)

if [[ -z "$CACHE_FILE" ]] || [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]; then
  [[ "$DEBUG" == "true" ]] && echo "claude-memory-hooks: Cache empty or build failed" >&2
  exit 0
fi

# --- Select memories to inject ---
# SessionStart mode: inject all feedback memories (behavioral rules are most actionable)
# If a prompt were available, we'd do keyword matching instead
MATCHED_FILES=$(bash "$SCRIPTS/match-memories.sh" "$PROMPT" "$CACHE_FILE" "$MAX_INJECTIONS" "$THRESHOLD" 2>/dev/null || true)

if [[ -z "$MATCHED_FILES" ]]; then
  [[ "$DEBUG" == "true" ]] && echo "claude-memory-hooks: No memories to inject" >&2
  exit 0
fi

# --- Build context block ---
CONTEXT="<memory-context>\nRelevant memories for this prompt (auto-injected by claude-memory-hooks):\n"
TOTAL_CHARS=0
MAX_TOTAL=80000
MAX_BODY=500

while IFS= read -r filepath; do
  [[ -z "$filepath" ]] && continue
  [[ ! -f "$filepath" ]] && continue

  # Parse frontmatter for display
  PARSED=$(bash "$SCRIPTS/parse-frontmatter.sh" "$filepath" 2>/dev/null || true)
  [[ -z "$PARSED" ]] && continue

  NAME=$(echo "$PARSED" | cut -f1)
  DESC=$(echo "$PARSED" | cut -f2)
  TYPE=$(echo "$PARSED" | cut -f3)
  TYPE_UPPER=$(echo "$TYPE" | tr '[:lower:]' '[:upper:]')

  # Extract body (everything after the second --- delimiter)
  BODY=$(awk 'BEGIN{c=0} /^---$/{c++;next} c>=2{print}' "$filepath" | head -c "$MAX_BODY")

  # Build entry
  ENTRY="\n[$TYPE_UPPER] $DESC\n$BODY"
  ENTRY_LEN=${#ENTRY}

  # Respect total size cap
  if (( TOTAL_CHARS + ENTRY_LEN > MAX_TOTAL )); then
    break
  fi

  CONTEXT="${CONTEXT}${ENTRY}\n"
  TOTAL_CHARS=$((TOTAL_CHARS + ENTRY_LEN))

done <<< "$MATCHED_FILES"

CONTEXT="${CONTEXT}\n</memory-context>"

[[ "$DEBUG" == "true" ]] && echo "claude-memory-hooks: Injecting $(echo "$MATCHED_FILES" | wc -l | tr -d ' ') memories" >&2

# --- Escape for JSON ---
escape_for_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

ESCAPED=$(escape_for_json "$(printf '%b' "$CONTEXT")")

# --- Output JSON (hookSpecificOutput format for plugin hooks) ---
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$ESCAPED"

exit 0
