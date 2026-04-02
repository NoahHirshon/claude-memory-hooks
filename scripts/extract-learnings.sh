#!/usr/bin/env bash
# extract-learnings.sh — Parse a session transcript and extract corrections/confirmations as memory files
# Input: $1=transcript path (JSONL), $2=output memory directory
# Output: creates new memory .md files, prints created file paths to stdout
# Requires: jq (exits cleanly if unavailable)

set -euo pipefail

TRANSCRIPT="$1"
OUTPUT_DIR="$2"

if [[ ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "claude-memory-hooks: jq required for learning extraction (skipping)" >&2
  exit 0
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

# --- Correction signal phrases (lowercase) ---
# Each phrase gets a weight. A message needs total weight >= 2 to trigger.
CORRECTION_PHRASES=(
  "don't do:1"
  "dont do:1"
  "stop doing:1"
  "never do:1"
  "wrong:1"
  "not like that:1"
  "that's not right:1"
  "thats not right:1"
  "i said:0.5"
  "i meant:0.5"
  "instead:0.5"
  "actually,:0.5"
  "not what i:1"
  "no,:0.5"
  "no.:0.5"
  "don't:0.5"
  "shouldn't:0.5"
  "not that:0.5"
)

# --- Confirmation signal phrases (need higher bar) ---
CONFIRMATION_PHRASES=(
  "yes exactly:2"
  "perfect:1"
  "remember this:2"
  "always do it:2"
  "keep doing that:2"
  "that's right:1"
  "thats right:1"
  "exactly right:2"
  "always do:1.5"
  "never change:1.5"
)

# --- Extract message pairs from transcript ---
# Build JSON array of {role, text} objects, filtering to text content only
MESSAGES=$(jq -c '
  select(.message.content != null) |
  .message.content[] |
  select(.type == "text") |
  {role: (input_filename // ""), text: .text}
' "$TRANSCRIPT" 2>/dev/null || true)

# Alternate approach: extract role and text from each line
PAIRS_FILE=$(mktemp)
trap 'rm -f "$PAIRS_FILE"' EXIT

jq -r '
  select(.message.content != null) |
  . as $msg |
  .message.content[] |
  select(.type == "text") |
  [$msg.role, .text] | @tsv
' "$TRANSCRIPT" 2>/dev/null > "$PAIRS_FILE" || true

if [[ ! -s "$PAIRS_FILE" ]]; then
  exit 0
fi

# --- Score a message against phrase patterns ---
score_message() {
  local msg_lower="$1"
  shift
  local phrases=("$@")
  local total=0

  for entry in "${phrases[@]}"; do
    local phrase="${entry%%:*}"
    local weight="${entry##*:}"
    if [[ "$msg_lower" == *"$phrase"* ]]; then
      total=$(awk "BEGIN{print $total + $weight}")
    fi
  done

  echo "$total"
}

# --- Scan for corrections and confirmations ---
LEARNINGS_COUNT=0
MAX_LEARNINGS=3
PAIR_INDEX=0
PREV_ROLE=""
PREV_TEXT=""

while IFS=$'\t' read -r role text; do
  PAIR_INDEX=$((PAIR_INDEX + 1))

  # Skip first 4 messages (session warmup — greetings, context loading)
  if [[ $PAIR_INDEX -le 4 ]]; then
    PREV_ROLE="$role"
    PREV_TEXT="$text"
    continue
  fi

  # Only analyze user messages that follow assistant messages
  if [[ "$role" == "user" ]] && [[ "$PREV_ROLE" == "assistant" ]]; then
    # Skip very short messages
    WORD_COUNT=$(echo "$text" | wc -w | tr -d ' ')
    if [[ $WORD_COUNT -lt 10 ]]; then
      PREV_ROLE="$role"
      PREV_TEXT="$text"
      continue
    fi

    MSG_LOWER=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Check for corrections
    CORRECTION_SCORE=$(score_message "$MSG_LOWER" "${CORRECTION_PHRASES[@]}")
    IS_CORRECTION=$(awk "BEGIN{print ($CORRECTION_SCORE >= 2) ? 1 : 0}")

    # Check for confirmations
    CONFIRM_SCORE=$(score_message "$MSG_LOWER" "${CONFIRMATION_PHRASES[@]}")
    IS_CONFIRMATION=$(awk "BEGIN{print ($CONFIRM_SCORE >= 2) ? 1 : 0}")

    if [[ "$IS_CORRECTION" == "1" ]] || [[ "$IS_CONFIRMATION" == "1" ]]; then
      # Cap learnings per session
      if [[ $LEARNINGS_COUNT -ge $MAX_LEARNINGS ]]; then
        break
      fi

      # Build description from user message (first 100 chars, cleaned)
      DESC=$(echo "$text" | head -c 100 | tr '\n' ' ' | sed 's/[^a-zA-Z0-9 .,!?-]//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

      # Build slug for filename
      SLUG=$(echo "$DESC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | head -c 40 | sed 's/_$//')

      FILENAME="feedback_learned_${SLUG}.md"
      FILEPATH="$OUTPUT_DIR/$FILENAME"

      # Deduplicate: check if similar memory already exists
      DUPLICATE=0
      if [[ -d "$OUTPUT_DIR" ]]; then
        while IFS= read -r existing; do
          [[ -z "$existing" ]] && continue
          EXISTING_DESC=$(grep '^description:' "$existing" 2>/dev/null | sed 's/^description: *//' || true)
          if [[ -n "$EXISTING_DESC" ]]; then
            # Simple overlap check: count shared words
            SHARED=$(comm -12 \
              <(echo "$DESC" | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' | sort -u) \
              <(echo "$EXISTING_DESC" | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' | sort -u) | wc -l | tr -d ' ')
            TOTAL=$(echo "$DESC" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
            if [[ $TOTAL -gt 0 ]] && awk "BEGIN{exit !($SHARED/$TOTAL > 0.7)}"; then
              DUPLICATE=1
              break
            fi
          fi
        done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "feedback_*.md" -type f 2>/dev/null)
      fi

      if [[ $DUPLICATE -eq 1 ]]; then
        continue
      fi

      # Determine learning type
      if [[ "$IS_CORRECTION" == "1" ]]; then
        LEARNING_TYPE="correction"
        CONTEXT_LINE="Extracted from a session correction."
      else
        LEARNING_TYPE="confirmation"
        CONTEXT_LINE="Extracted from a confirmed approach."
      fi

      # Write memory file (atomic, safe from injection)
      TEMP="${FILEPATH}.tmp.$$"
      trap 'rm -f "$TEMP"' EXIT
      PREV_TRUNCATED=$(printf '%s' "$PREV_TEXT" | head -c 300)
      {
        printf '%s\n' "---"
        printf 'name: %s\n' "$FILENAME"
        printf 'description: %s\n' "$DESC"
        printf '%s\n' "type: feedback"
        printf '%s\n' "---"
        printf '\n%s\n' "$CONTEXT_LINE"
        printf '\n**User said:** %s\n' "$text"
        printf '\n**Context (what Claude was doing):** %s\n' "$PREV_TRUNCATED"
        printf '\n%s\n' "**How to apply:** Follow the user'\''s guidance in future similar situations."
      } > "$TEMP"
      mv "$TEMP" "$FILEPATH"

      # Append to MEMORY.md index if it exists
      MEMORY_INDEX="$OUTPUT_DIR/MEMORY.md"
      if [[ -f "$MEMORY_INDEX" ]]; then
        # Check if entry already exists
        if ! grep -q "$FILENAME" "$MEMORY_INDEX" 2>/dev/null; then
          echo "- [$FILENAME]($FILENAME) — $DESC" >> "$MEMORY_INDEX"
        fi
      fi

      echo "$FILEPATH"
      LEARNINGS_COUNT=$((LEARNINGS_COUNT + 1))
    fi
  fi

  PREV_ROLE="$role"
  PREV_TEXT="$text"
done < "$PAIRS_FILE"
