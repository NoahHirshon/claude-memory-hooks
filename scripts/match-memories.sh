#!/usr/bin/env bash
# match-memories.sh -- Score memory files against a user prompt using keyword intersection + IDF
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

# Two-pass awk: first pass builds doc_freq (IDF), second pass scores
awk -F'\t' -v prompt="$PROMPT" -v max_results="$MAX_RESULTS" -v threshold="$THRESHOLD" '
BEGIN {
  # Stop words - common English words that add noise to matching
  # Core stop words
  split("the a an is are was were be been being have has had do does did will would could should may might can shall to of in for on with at by from as into through during before after above below between under about it this that these those i me my we our you your he she they them their what which who whom when where why how all each every both few more most other some such no not only same so than too very just because but and or if then else also here there now", sw, " ")
  for (i in sw) stop_words[sw[i]] = 1
  # Task/action stop words
  split("let make want need like know think look get go see come project app check work help fix bug update change file files build code run start stop use using used please sure thing things right looking", sw2, " ")
  for (i in sw2) stop_words[sw2[i]] = 1
  # Round 8 additions - low-signal adjectives/verbs
  split("active current new old latest last first next best good bad great little big small open close read write send post try set done got put took went came saw made", sw3, " ")
  for (i in sw3) stop_words[sw3[i]] = 1

  # Tokenize prompt: lowercase, strip punctuation (including em-dashes), remove stop words, limit to 200 words
  gsub(/\xe2\x80\x94/, " ", prompt)  # em-dash
  gsub(/\xe2\x80\x93/, " ", prompt)  # en-dash
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

  # Save original count before synonym expansion
  original_prompt_count = prompt_token_count

  # Tiered synonym expansion with per-group weights
  # Tight synonyms (0.8-0.9)
  if ("email" in prompt_tokens) { synonym_weight["mail"]=0.9; synonym_weight["gmail"]=0.9; synonym_weight["inbox"]=0.8 }
  if ("spreadsheet" in prompt_tokens) { synonym_weight["xlsx"]=0.9; synonym_weight["excel"]=0.9; synonym_weight["workbook"]=0.8 }
  if ("terminal" in prompt_tokens) { synonym_weight["shell"]=0.8; synonym_weight["cli"]=0.8; synonym_weight["command"]=0.6 }
  if ("subscription" in prompt_tokens || "subscriptions" in prompt_tokens) { synonym_weight["billing"]=0.7; synonym_weight["payment"]=0.6; synonym_weight["cost"]=0.5 }

  # Medium synonyms (0.5-0.7)
  if ("website" in prompt_tokens) { synonym_weight["site"]=0.9; synonym_weight["web"]=0.8; synonym_weight["vercel"]=0.5; synonym_weight["deploy"]=0.4 }
  if ("resume" in prompt_tokens) { synonym_weight["cv"]=0.9; synonym_weight["application"]=0.5 }
  if ("phone" in prompt_tokens) { synonym_weight["iphone"]=0.9; synonym_weight["mobile"]=0.8; synonym_weight["device"]=0.4 }

  # Loose synonyms (0.3)
  if ("golf" in prompt_tokens) { synonym_weight["trackman"]=0.8; synonym_weight["range"]=0.4; synonym_weight["round"]=0.3 }

  # Job/career synonyms
  if ("interview" in prompt_tokens) { synonym_weight["hiring"]=0.7; synonym_weight["job"]=0.6; synonym_weight["recruit"]=0.6; synonym_weight["candidate"]=0.5 }
  if ("employer" in prompt_tokens) { synonym_weight["hiring"]=0.7; synonym_weight["company"]=0.6; synonym_weight["recruiter"]=0.5 }
  if ("job" in prompt_tokens) { synonym_weight["career"]=0.7; synonym_weight["employment"]=0.7; synonym_weight["role"]=0.5; synonym_weight["position"]=0.5 }

  # Financial synonyms
  if ("money" in prompt_tokens || "finances" in prompt_tokens) { synonym_weight["debt"]=0.7; synonym_weight["income"]=0.7; synonym_weight["savings"]=0.6; synonym_weight["credit"]=0.5 }
  if ("worth" in prompt_tokens) { synonym_weight["debt"]=0.6; synonym_weight["assets"]=0.7; synonym_weight["balance"]=0.5 }

  # Agent/automation synonyms
  if ("agent" in prompt_tokens || "agents" in prompt_tokens) { synonym_weight["scheduled"]=0.7; synonym_weight["automation"]=0.7; synonym_weight["task"]=0.6; synonym_weight["daemon"]=0.5 }
  if ("ssh" in prompt_tokens) { synonym_weight["remote"]=0.7; synonym_weight["server"]=0.6; synonym_weight["headless"]=0.5 }

  # People synonyms
  if ("contact" in prompt_tokens || "contacts" in prompt_tokens) { synonym_weight["person"]=0.6; synonym_weight["people"]=0.6; synonym_weight["friend"]=0.5 }

  # Remove synonyms that are already prompt tokens or stop words
  for (sw_syn in synonym_weight) {
    if (sw_syn in prompt_tokens || sw_syn in stop_words) {
      delete synonym_weight[sw_syn]
    }
  }

  if (prompt_token_count == 0) exit

  total_docs = 0
}

# Main loop: store all lines and build document frequency counts
{
  total_docs++
  stored_filepath[total_docs] = $1
  stored_desc[total_docs] = $2
  stored_type[total_docs] = $3
  stored_name[total_docs] = $4

  if ($2 == "") next

  # Tokenize description + name for doc_freq counting
  desc_clean = $2 " " $4
  gsub(/\xe2\x80\x94/, " ", desc_clean)
  gsub(/\xe2\x80\x93/, " ", desc_clean)
  gsub(/[^a-zA-Z0-9 ]/, " ", desc_clean)
  desc_lower = tolower(desc_clean)
  m = split(desc_lower, dw_arr, /[[:space:]]+/)

  # Count unique tokens per document for document frequency
  delete seen_in_doc
  for (j = 1; j <= m; j++) {
    tok = dw_arr[j]
    if (length(tok) < 2) continue
    if (tok in stop_words) continue
    if (!(tok in seen_in_doc)) {
      seen_in_doc[tok] = 1
      doc_freq[tok]++
    }
  }
}

END {
  if (total_docs == 0) exit

  # Precompute max_idf for normalization: log(total_docs)
  max_idf = log(total_docs)
  if (max_idf <= 0) max_idf = 1  # safety for single-doc edge case

  match_count = 0

  # Second pass: score each stored entry
  for (i = 1; i <= total_docs; i++) {
    filepath = stored_filepath[i]
    desc = stored_desc[i]
    type = stored_type[i]
    name = stored_name[i]

    if (desc == "") continue

    # Tokenize description + name
    desc_clean = desc " " name
    gsub(/\xe2\x80\x94/, " ", desc_clean)
    gsub(/\xe2\x80\x93/, " ", desc_clean)
    gsub(/[^a-zA-Z0-9 ]/, " ", desc_clean)
    desc_lower = tolower(desc_clean)
    m = split(desc_lower, desc_words, /[[:space:]]+/)

    # Build unique token set for this document (set-dedup)
    delete doc_unique_tokens
    for (j = 1; j <= m; j++) {
      dw = desc_words[j]
      if (length(dw) < 2) continue
      if (dw in stop_words) continue
      doc_unique_tokens[dw] = 1
    }

    # Count matching tokens with IDF weighting (iterate unique tokens only)
    matches = 0
    for (dw in doc_unique_tokens) {
      # Calculate IDF weight for this description token
      df = (dw in doc_freq) ? doc_freq[dw] : 0
      idf = (df > 0 && max_idf > 0) ? log(total_docs / (1 + df)) / max_idf : 1.0

      if (dw in prompt_tokens) {
        matches += idf
      } else if (dw in synonym_weight) {
        matches += synonym_weight[dw] * idf
      }
    }

    # Token overlap score - use original (pre-synonym) count as denominator
    token_score = (original_prompt_count > 0) ? matches / original_prompt_count : 0

    # Type boost: feedback gets priority (most actionable)
    type_boost = 0
    if (type == "feedback") type_boost = 0.04
    else if (type == "user") type_boost = 0.05

    # Final score
    score = token_score + type_boost

    if (score >= threshold) {
      match_count++
      scores[match_count] = score
      paths[match_count] = filepath
    }
  }

  if (match_count == 0) exit

  # Sort by score descending (simple selection sort - fine for <200 entries)
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
