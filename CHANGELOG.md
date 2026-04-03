# Changelog

## 2026-04-03

- Fix duplicate memory injections caused by auto-discovered project directory overlapping with config `memoryDirs`. Added `sort -u` dedup on resolved directories before cache build.

## 2026-04-02

- Switch to per-prompt keyword matching via `UserPromptSubmit` hook
- Fix stdin field name (`user_prompt` -> `prompt`), newline-in-prompt awk breakage
- Harden for production: security, config defaults, docs

## 2026-04-02 (initial)

- Initial release: memory injection and learning extraction for Claude Code
