#!/usr/bin/env bash
# build-cache.sh — Scan memory directories and build a TSV description index
# Input: space-separated directory paths as arguments
# Output: writes cache file, prints cache path to stdout
# Cache format: filepath\tdescription\ttype\tname (one line per .md file)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_FILE="/tmp/claude-memory-hooks-cache-${USER:-default}.tsv"
CACHE_TTL=300  # 5 minutes

# Check if cache is fresh enough
needs_rebuild() {
  # No cache file — rebuild
  [[ ! -f "$CACHE_FILE" ]] && return 0

  # Cache older than TTL — rebuild
  local cache_age
  if [[ "$(uname)" == "Darwin" ]]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
  else
    cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
  fi
  [[ $cache_age -gt $CACHE_TTL ]] && return 0

  # Any .md file newer than cache — rebuild
  for dir in "$@"; do
    [[ ! -d "$dir" ]] && continue
    newer=$(find "$dir" -name "*.md" -newer "$CACHE_FILE" 2>/dev/null | head -1)
    [[ -n "$newer" ]] && return 0
  done

  return 1
}

if ! needs_rebuild "$@"; then
  echo "$CACHE_FILE"
  exit 0
fi

# Rebuild cache
TEMP_CACHE="${CACHE_FILE}.tmp.$$"
: > "$TEMP_CACHE"

for dir in "$@"; do
  [[ ! -d "$dir" ]] && continue

  while IFS= read -r file; do
    # Skip index files and non-memory files
    bname=$(basename "$file")
    [[ "$bname" == "MEMORY.md" ]] && continue
    [[ "$bname" == "README.md" ]] && continue
    [[ "$bname" =~ ^\. ]] && continue

    # Parse frontmatter
    parsed=$(bash "$SCRIPT_DIR/parse-frontmatter.sh" "$file" 2>/dev/null || true)

    if [[ -n "$parsed" ]]; then
      name=$(echo "$parsed" | cut -f1)
      desc=$(echo "$parsed" | cut -f2)
      type=$(echo "$parsed" | cut -f3)
      printf '%s\t%s\t%s\t%s\n' "$file" "$desc" "$type" "$name" >> "$TEMP_CACHE"
    fi
  done < <(find "$dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)
done

mv "$TEMP_CACHE" "$CACHE_FILE"
echo "$CACHE_FILE"
