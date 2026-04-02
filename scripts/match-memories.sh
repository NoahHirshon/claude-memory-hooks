#!/usr/bin/env bash
# match-memories.sh — Score memory files against a user prompt using keyword intersection
# Input: $1=prompt, $2=cache file path, $3=max results, $4=relevance threshold
# Output: matched file paths to stdout (one per line, highest score first)

set -euo pipefail

PROMPT="$1"
CACHE_FILE="$2"
MAX_RESULTS="${3:-3}"
THRESHOLD="${4:-0.25}"

if [[ ! -f "$CACHE_FILE" ]] || [[ -z "$PROMPT" ]]; then
  exit 0
fi

# Single awk pass: tokenize prompt, score each cache line, output top matches
awk -F'\t' -v prompt="$PROMPT" -v max_results="$MAX_RESULTS" -v threshold="$THRESHOLD" '
BEGIN {
  # Stop words — common English words that add noise to matching
  split("the a an is are was were be been being have has had do does did will would could should may might can shall to of in for on with at by from as into through during before after above below between under about it this that these those i me my we our you your he she they them their what which who whom when where why how all each every both few more most other some such no not only same so than too very just because but and or if then else also here there now let make want need like know think look get go see come", sw, " ")
  for (i in sw) stop_words[sw[i]] = 1

  # Tokenize prompt: lowercase, strip punctuation, remove stop words, limit to 200 words
  gsub(/[^a-zA-Z0-9 ]/, " ", prompt)
  prompt_lower = tolower(prompt)
  n = split(prompt_lower, words, /[[:space:]]+/)
  prompt_token_count = 0
  for (i = 1; i <= n && prompt_token_count < 200; i++) {
    w = words[i]
    if (length(w) < 2) continue
    if (w in stop_words) continue
    prompt_tokens[w] = 1
    prompt_token_count++
  }

  if (prompt_token_count == 0) exit

  match_count = 0
}

# Process each cache line: filepath \t description \t type \t name
{
  filepath = $1
  desc = $2
  type = $3
  name = $4

  if (desc == "") next

  # Tokenize description + name combined (name adds keywords like "xlsx", "golf", etc.)
  desc_clean = desc " " name
  gsub(/[^a-zA-Z0-9 ]/, " ", desc_clean)
  desc_lower = tolower(desc_clean)
  m = split(desc_lower, desc_words, /[[:space:]]+/)

  # Count matching tokens
  matches = 0
  for (j = 1; j <= m; j++) {
    dw = desc_words[j]
    if (length(dw) < 2) continue
    if (dw in stop_words) continue
    if (dw in prompt_tokens) matches++
  }

  # Token overlap score
  token_score = (prompt_token_count > 0) ? matches / prompt_token_count : 0

  # Type boost: feedback gets priority (most actionable)
  type_boost = 0
  if (type == "feedback") type_boost = 0.15
  else if (type == "user") type_boost = 0.05

  # Final score
  score = token_score + type_boost

  if (score >= threshold) {
    match_count++
    scores[match_count] = score
    paths[match_count] = filepath
  }
}

END {
  if (match_count == 0) exit

  # Sort by score descending (simple selection sort — fine for <200 entries)
  for (i = 1; i <= match_count; i++) {
    max_idx = i
    for (j = i + 1; j <= match_count; j++) {
      if (scores[j] > scores[max_idx]) max_idx = j
    }
    if (max_idx != i) {
      tmp_s = scores[i]; scores[i] = scores[max_idx]; scores[max_idx] = tmp_s
      tmp_p = paths[i]; paths[i] = paths[max_idx]; paths[max_idx] = tmp_p
    }
  }

  # Output top N
  limit = (match_count < max_results) ? match_count : max_results
  for (i = 1; i <= limit; i++) {
    print paths[i]
  }
}
' "$CACHE_FILE"
