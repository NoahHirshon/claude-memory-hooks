# claude-memory-hooks

**Your Claude Code memories, automatically injected at session start.**

A Claude Code plugin that turns passive memory files into active context. Instead of hoping Claude reads the right memory at the right time, this plugin loads your memory library into context at the start of every session — behavioral rules, project context, preferences, and references.

Two hooks:
1. **Memory Injection** (SessionStart) — Loads all your memory files into Claude's context when a session begins. Feedback memories (behavioral rules) are prioritized first.
2. **Learning Extraction** (Stop) — Scans the session transcript for corrections and confirmations. Saves them as new memory files automatically.

The result: a recursive learning loop. You correct Claude once, the correction becomes a memory, and that memory gets injected at the start of every future session.

## Setup (30 seconds)

```bash
# Clone
git clone https://github.com/NoahHirshon/claude-memory-hooks.git

# Edit config.json — point at your memory directory
# Default: ~/.claude/memory
# The plugin also auto-discovers project-scoped memory at
# ~/.claude/projects/{project-key}/memory/

# Launch Claude Code with the plugin
claude --plugin-dir /path/to/claude-memory-hooks
```

That's it. Your memories will inject automatically at session start.

To make it permanent, add an alias to your shell config:
```bash
# ~/.zshrc or ~/.bashrc
alias claude='claude --plugin-dir /path/to/claude-memory-hooks'
```

## How It Works

```
Session starts
       |
       v
[SessionStart hook fires]
       |
       v
Load all memory files, prioritize by type
(feedback > user > project > reference)
       |
       v
Inject as <memory-context> block into Claude's context
       |
       v
Claude sees your memories for the entire session
       |
       v
You correct Claude ("don't do that", "always do X")
       |
       v
[Stop hook fires at session end]
       |
       v
Correction extracted, saved as new memory file
       |
       v
Next session: that correction is in context from the start
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

**Types** (injected in this priority order):
- `feedback` — Behavioral rules from corrections. Most actionable — injected first.
- `user` — Identity, preferences, communication style.
- `project` — Architecture decisions, project context.
- `reference` — External commands, API details, working code snippets.

Files without YAML frontmatter are also supported — the first content line is used as the description.

The `description` field is what the matching algorithm uses for per-prompt matching (when available). Write it as a keyword-rich one-liner.

## What Claude Sees

At session start, Claude receives all your memories:

```xml
<memory-context>
Relevant memories for this prompt (auto-injected by claude-memory-hooks):

[FEEDBACK] Before modifying any .xlsx file, read sheet names, column headers, sample rows
Never assume spreadsheet structure from memory. Before writing:
1. Read sheet names
2. Read column headers
3. Read 3-5 sample rows

[FEEDBACK] Read every row for data queries, never filter or interpret
When asked to find data matching criteria, read EVERY row and check each one.
Never use keyword shortcuts that could miss entries.

[USER] Noah prefers direct communication, no preamble
Lead with the answer. No flattery. Use plain language and analogies.
</memory-context>
```

## Configuration

Edit `config.json` at the plugin root:

```json
{
  "memoryDirs": ["~/.claude/memory"],
  "maxInjections": 50,
  "relevanceThreshold": 0.25,
  "learningEnabled": true,
  "debugMode": false
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `memoryDirs` | `["~/.claude/memory"]` | Directories to scan for memory files. Supports `~`. |
| `maxInjections` | `50` | Maximum memories injected per session. |
| `relevanceThreshold` | `0.25` | Minimum score (0-1) for per-prompt matching. |
| `learningEnabled` | `true` | Whether the Stop hook extracts learnings from sessions. |
| `debugMode` | `false` | Log matching decisions to stderr. |

**Project-scoped memory** is auto-discovered from the working directory. If you're in `/Users/you/myproject`, the plugin also checks `~/.claude/projects/-Users-you-myproject/memory/`.

## Per-Prompt Matching

The plugin also includes a keyword matching algorithm for per-prompt memory injection. This is designed for `UserPromptSubmit` hooks, which are currently affected by a [known Claude Code bug](https://github.com/anthropics/claude-code/issues/12151) where hook output is silently dropped.

Once that bug is fixed, the plugin can switch from session-wide injection to per-prompt injection — matching the most relevant 3-5 memories against each specific prompt. The matching algorithm uses weighted keyword intersection:

1. Tokenize prompt and memory descriptions (lowercase, strip punctuation, remove stop words)
2. Score = overlapping tokens / total prompt tokens
3. Feedback memories get a +0.15 boost, user memories get +0.05
4. Scores above `relevanceThreshold` are injected

To enable per-prompt matching manually, change `hooks.json` to use `UserPromptSubmit` instead of `SessionStart` and test whether your Claude Code version has the fix.

## Learning Extraction

The Stop hook scans for corrections and confirmations:

**Corrections** (what you told Claude to stop doing):
- Signal phrases: "don't do that", "wrong", "not like that", "never do", "instead"
- Requires 2+ signals per message (prevents false positives)

**Confirmations** (approaches you explicitly validated):
- Signal phrases: "yes exactly", "perfect", "remember this", "always do it this way"
- Higher bar — requires strong signals or explicit "remember" language

**Guardrails:**
- Minimum 10 words per candidate message
- Skips first 4 messages (session warmup)
- Maximum 3 learnings per session
- Deduplicates against existing memories (70% token overlap)
- Requires `jq` for transcript parsing (exits gracefully if unavailable)

## Requirements

- Claude Code v2.1+
- bash (macOS/Linux)
- `jq` — optional but recommended (required for learning extraction; injection works without it)

## Privacy

Everything stays on your machine. No external services, no API keys, no data transmitted anywhere. Memory files are local markdown. The cache is at `/tmp/` and ephemeral.

## Architecture

```
claude-memory-hooks/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   ├── hooks.json               # Hook registration (SessionStart + Stop)
│   ├── memory-inject.sh         # Injection hook — loads memories into context
│   └── learning-extract.sh      # Extraction hook — saves corrections as memories
├── scripts/
│   ├── match-memories.sh        # Keyword matching algorithm (single awk pass)
│   ├── parse-frontmatter.sh     # YAML frontmatter parser
│   ├── build-cache.sh           # TSV index cache builder
│   └── extract-learnings.sh     # Transcript analysis + memory file creation
├── config.json                  # User configuration
├── CLAUDE.md                    # Plugin dev context
├── LICENSE                      # MIT
└── README.md
```

All bash. No npm, no pip, no databases, no API keys. 11 files.

## FAQ

**How fast is it?**
Under 500ms for typical memory libraries (<200 files). The 10-second timeout is generous.

**What if I have no memory files yet?**
Create your first one at `~/.claude/memory/` with the YAML frontmatter format above. The plugin picks it up on the next session.

**Why SessionStart instead of UserPromptSubmit?**
A [known bug](https://github.com/anthropics/claude-code/issues/12151) causes UserPromptSubmit hook output to be silently dropped. SessionStart works reliably. When the bug is fixed, per-prompt matching will unlock more targeted injection.

**Can I use this with Cursor/Copilot CLI?**
The output format auto-detects the platform (Claude Code, Cursor, Copilot CLI).

**How do I see what's being injected?**
Set `"debugMode": true` in config.json. Matching decisions are logged to stderr.

**Can I disable learning extraction but keep injection?**
Yes. Set `"learningEnabled": false` in config.json.

**How does this compare to claude-subconscious?**
Both solve persistent memory. claude-subconscious uses a background Letta agent on external servers. This plugin is fully local, zero dependencies, and works with plain markdown files you control.

## Inspired By

- [letta-ai/claude-subconscious](https://github.com/letta-ai/claude-subconscious) — Background agent memory for Claude Code
- [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) — Session compression and context injection
- [obra/superpowers](https://github.com/obra/superpowers) — SessionStart hook pattern for context injection

## License

MIT
