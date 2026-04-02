# claude-memory-hooks

**Your Claude Code memories, matched and injected before every prompt.**

A Claude Code plugin that turns passive memory files into active context. Every time you send a prompt, the plugin scores your memory library against what you just typed and injects the most relevant memories before Claude starts thinking.

Two hooks:
1. **Memory Injection** (UserPromptSubmit) — Keyword-matches your prompt against memory file descriptions. Top matches get injected as context before Claude processes your message.
2. **Learning Extraction** (Stop) — Scans the session transcript for corrections and confirmations. Saves them as new memory files automatically.

The result: a recursive learning loop. You correct Claude once, the correction becomes a memory, and that memory gets injected every time a similar prompt comes up.

## Setup (30 seconds)

```bash
# Clone
git clone https://github.com/NoahHirshon/claude-memory-hooks.git

# Copy the example config and point at your memory directory
cp config.example.json config.json
# Default: ~/.claude/memory
# The plugin also auto-discovers project-scoped memory at
# ~/.claude/projects/{project-key}/memory/

# Launch Claude Code with the plugin
claude --plugin-dir /path/to/claude-memory-hooks
```

To make it permanent, add an alias to your shell config:
```bash
# ~/.zshrc or ~/.bashrc
alias claude='claude --plugin-dir /path/to/claude-memory-hooks'
```

That's it. Every prompt you send will now trigger memory matching and injection.

## How It Works

```
You type: "update the golf spreadsheet with my latest round"
       |
       v
[UserPromptSubmit hook fires]
       |
       v
Tokenize prompt → ["update", "golf", "spreadsheet", "latest", "round"]
Score each memory description against those keywords
       |
       v
Top 3-5 matches injected as <memory-context>
       |
       v
Claude sees: your prompt + relevant memories
  e.g. "Always read Excel structure before writing"
       "Read every row for data queries"
       |
       v
You work, then correct Claude ("don't do that", "always do X")
       |
       v
[Stop hook fires at session end]
       |
       v
Correction extracted → saved as new memory file
       |
       v
Next prompt mentioning similar keywords → that correction auto-injects
```

## Memory File Format

Memory files are markdown with YAML frontmatter:

```yaml
---
name: Always read Excel structure first
description: Before modifying any .xlsx file, read sheet names, column headers, sample rows
type: feedback
---

Never assume spreadsheet structure from memory. Before writing:
1. Read sheet names
2. Read column headers
3. Read 3-5 sample rows
```

The `description` field is critical — it's what the matching algorithm scores against your prompt. Write it as a keyword-rich one-liner.

**Types** (feedback gets a scoring boost):
- `feedback` — Behavioral rules from corrections. Most actionable. +0.15 score boost.
- `user` — Identity, preferences, communication style. +0.05 score boost.
- `project` — Architecture decisions, project context.
- `reference` — External commands, API details, working code snippets.

Files without YAML frontmatter are also supported — the first content line is used as the description.

## What Claude Sees

When you type "update the golf spreadsheet," Claude receives:

```xml
<memory-context>
Relevant memories for this prompt (auto-injected by claude-memory-hooks):

[FEEDBACK] Always read Excel spreadsheet contents before writing — row layout must be verified first
Never assume spreadsheet structure from memory. Before writing:
1. Read sheet names  2. Read column headers  3. Read 3-5 sample rows

[FEEDBACK] Two hard rules for data queries — read every single row, never filter or interpret
When asked to find data matching criteria, read EVERY row and check each one.
Never use keyword shortcuts that could miss entries.
</memory-context>
```

Different prompts get different memories. "Fix the SwiftUI navigation bug" would match UI design workflow memories instead.

## Matching Algorithm

Weighted keyword intersection — fast, no dependencies, single `awk` pass:

1. **Tokenize** — lowercase prompt and each memory description, strip punctuation, remove ~80 stop words
2. **Score** — count overlapping tokens / total prompt tokens
3. **Boost** — feedback memories get +0.15 (corrections are the most actionable context), user memories get +0.05
4. **Filter** — scores above `relevanceThreshold` (default 0.25) are candidates
5. **Rank** — top `maxInjections` (default 5) are injected, highest score first

The name field is also included in matching, so a file named `feedback_xlsx_read_first.md` gets extra keyword signal from "xlsx."

**Performance:** Under 200ms for typical memory libraries (<200 files). Cache rebuilds only when files change.

## Configuration

Copy `config.example.json` to `config.json` and edit:

```json
{
  "memoryDirs": ["~/.claude/memory"],
  "maxInjections": 5,
  "relevanceThreshold": 0.25,
  "learningEnabled": true,
  "debugMode": false
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `memoryDirs` | `["~/.claude/memory"]` | Directories to scan for memory files. Supports `~`. |
| `maxInjections` | `5` | Maximum memories injected per prompt. |
| `relevanceThreshold` | `0.25` | Minimum score (0-1) to inject a memory. Lower = more memories, higher = stricter. |
| `learningEnabled` | `true` | Whether the Stop hook extracts learnings from sessions. |
| `debugMode` | `false` | Log matching decisions to stderr. |

**Project-scoped memory** is auto-discovered from the working directory. If you're in `/Users/you/myproject`, the plugin also checks `~/.claude/projects/-Users-you-myproject/memory/` automatically — no config needed.

## Learning Extraction

The Stop hook scans your session transcript for corrections and confirmations:

**Corrections** (what you told Claude to stop doing):
- Signal phrases: "don't do that", "wrong", "not like that", "never do", "instead"
- Requires 2+ signals per message (prevents false positives from casual "no")

**Confirmations** (approaches you explicitly validated):
- Signal phrases: "yes exactly", "perfect", "remember this", "always do it this way"
- Higher bar — requires strong signals or explicit "remember" language

**Guardrails:**
- Minimum 10 words per candidate message
- Skips first 4 messages (session warmup)
- Maximum 3 learnings per session
- Deduplicates against existing memories (70% token overlap)
- Requires `jq` for transcript parsing (exits gracefully if unavailable)

Extracted memories are saved with proper YAML frontmatter and appended to your MEMORY.md index.

## Architecture

```
claude-memory-hooks/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   ├── hooks.json               # Hook registration (UserPromptSubmit + Stop)
│   ├── memory-inject.sh         # Injection — matches prompt, injects memories
│   └── learning-extract.sh      # Extraction — saves corrections as memories
├── scripts/
│   ├── match-memories.sh        # Keyword matching algorithm (single awk pass)
│   ├── parse-frontmatter.sh     # YAML frontmatter parser
│   ├── build-cache.sh           # TSV index cache builder (5-min TTL)
│   └── extract-learnings.sh     # Transcript analysis + memory file creation
├── config.example.json          # Example configuration (copy to config.json)
├── CLAUDE.md                    # Plugin dev context
├── LICENSE                      # MIT
└── README.md
```

All bash. No npm, no pip, no databases, no API keys.

## Requirements

- Claude Code v2.1.88+
- bash (macOS/Linux)
- `jq` — optional but recommended (required for learning extraction; injection works without it)

## Privacy

Everything stays on your machine. No external services, no API keys, no data transmitted anywhere. Memory files are local markdown. The cache lives at `/tmp/` and is ephemeral.

## FAQ

**How fast is it?**
Under 200ms for typical memory libraries. The 5-second hook timeout is generous.

**What if no memories match my prompt?**
Nothing gets injected. Claude sees your prompt as normal — zero overhead.

**What if I have no memory files yet?**
Create your first one at `~/.claude/memory/` with the YAML frontmatter format above. The plugin picks it up immediately.

**How do I see what's being injected?**
Set `"debugMode": true` in config.json. Matching decisions are logged to stderr.

**Can I disable learning extraction but keep injection?**
Yes. Set `"learningEnabled": false` in config.json.

**How does this compare to claude-subconscious?**
Both solve persistent memory. claude-subconscious uses a background Letta agent on external servers. This plugin is fully local, zero dependencies, and works with plain markdown files you control.

## Inspired By

- [letta-ai/claude-subconscious](https://github.com/letta-ai/claude-subconscious) — Background agent memory for Claude Code
- [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) — Session compression and context injection
- [obra/superpowers](https://github.com/obra/superpowers) — Plugin hook patterns for context injection

## License

MIT
