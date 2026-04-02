#!/usr/bin/env bash
# parse-frontmatter.sh — Extract name, description, type from a memory file's YAML frontmatter
# Input: file path as $1
# Output: tab-separated "name\tdescription\ttype" to stdout
# Falls back to first content line as description if no frontmatter found

set -euo pipefail

FILE="$1"

if [[ ! -f "$FILE" ]]; then
  exit 0
fi

# Extract YAML frontmatter (content between first pair of --- delimiters)
FRONTMATTER=$(awk '/^---$/{c++;next} c==1{print} c>=2{exit}' "$FILE" 2>/dev/null || true)

if [[ -z "$FRONTMATTER" ]]; then
  # No frontmatter — use first non-empty, non-heading line as description
  DESC=$(grep -m1 -v -e '^#' -e '^$' -e '^---' "$FILE" 2>/dev/null | head -c 200 || true)
  NAME=$(basename "$FILE" .md)
  TYPE="unknown"
  if [[ -n "$DESC" ]]; then
    printf '%s\t%s\t%s\n' "$NAME" "$DESC" "$TYPE"
  fi
  exit 0
fi

NAME=$(echo "$FRONTMATTER" | grep '^name:' | sed 's/^name: *//' | head -1)
DESC=$(echo "$FRONTMATTER" | grep '^description:' | sed 's/^description: *//' | head -1)
TYPE=$(echo "$FRONTMATTER" | grep '^type:' | sed 's/^type: *//' | head -1)

# Use filename as fallback for name
if [[ -z "$NAME" ]]; then
  NAME=$(basename "$FILE" .md)
fi

# Only output if we have a description (needed for matching)
if [[ -n "$DESC" ]]; then
  printf '%s\t%s\t%s\n' "$NAME" "$DESC" "$TYPE"
fi
