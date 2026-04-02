# claude-memory-hooks

Claude Code plugin that injects relevant memories before each prompt and extracts learnings at session end.

## Architecture

- **hooks/memory-inject.sh** — SessionStart hook. Loads memory files, prioritizes by type, injects into context. Also supports per-prompt matching via UserPromptSubmit (pending Anthropic bug fix).
- **hooks/learning-extract.sh** — Stop hook. Parses transcript for corrections/confirmations, writes new memory files.
- **scripts/match-memories.sh** — Keyword intersection scoring algorithm (single awk pass).
- **scripts/build-cache.sh** — Builds TSV index of memory file descriptions. Cached at /tmp/, refreshes when files change.
- **scripts/parse-frontmatter.sh** — Extracts name/description/type from YAML frontmatter.
- **scripts/extract-learnings.sh** — Transcript analysis. Identifies corrections (2+ signal phrases) and confirmations (high bar). Max 3 per session.

## Memory File Format

```yaml
---
name: Display Name
description: One-line description (used for matching)
type: feedback | project | reference | user
---

Body content here.
```

## Key Conventions

- All scripts are bash. No external dependencies except optional jq.
- JSON output follows Claude Code's hookSpecificOutput.additionalContext pattern.
- Cross-platform output: supports Claude Code, Cursor, and Copilot CLI.
- Atomic writes: temp file + mv pattern for all file creation.
- Config at plugin root: config.json with memoryDirs, thresholds, toggles.

## Build & Test

```bash
# Test injection hook directly
echo '{"user_prompt":"update the spreadsheet","cwd":"/tmp"}' | bash hooks/memory-inject.sh

# Test with real memory directory
# Edit config.json memoryDirs first, then run above

# Install as Claude Code plugin
cd /path/to/claude-memory-hooks && claude /plugin enable .
```
