# Changelog

## 0.3.0 — 2026-06-10

Token-cost rework of the background card generator (see
`docs/OPTIMIZATION-HANDOFF-2026-06-10.md`). The old design re-sent the WHOLE chat (≤40000 chars),
uncached, on EVERY Stop just to keep TASK/PREVIOUS fresh — ~74 Sonnet calls/day across ~49 sessions
≈ 760K tokens/day, almost all input. The concept (live Name+Goal card + goal-keeper) is unchanged.

- **Settled sessions now cost ZERO background tokens.** Name and Goal are generated once from a small
  early slice and frozen; after that, with the live fields off (the default), `topic-update.sh` no
  longer spawns the worker at all. The dominant drain (the recurring whole-chat TASK/PREVIOUS call)
  is gone from the default path.
- **TASK / PREVIOUS are now optional and OFF by default** — `WCT_TASK_FIELD` / `WCT_PREVIOUS_FIELD`
  (PREVIOUS requires TASK). When off, those card lines are simply blank (the renderer already handles
  empty lines). The worker keeps any old TASK/PREVIOUS rather than wiping them on a non-task run.
- **GOAL refresh policy** — `WCT_GOAL_REFRESH=once` (default, freeze after first gen) | `periodic`
  (re-derive every `WCT_GOAL_REFRESH_SECONDS`, default 3600) | `off` (never generate GOAL; the first
  card line falls back to NAME).
- **Tighter, configurable input caps** — `WCT_GOAL_INPUT_CHARS` (default 12000, was 40000),
  `WCT_NAME_INPUT_CHARS` (4000), `WCT_RECENT_INPUT_CHARS` (6000). GOAL is now **head-anchored** to the
  chat opening (intent lives early) instead of `tail -c` of the whole chat (audit finding 20).
- **Decorative banner removed** from the MAIN system prompt (audit finding 17) — it was parsed off and
  discarded anyway; every banner byte was billed output.
- **Real token-usage logging** — `WCT_LOG_USAGE=1` (default on) runs each call with
  `--output-format json` and appends a `USAGE … in=… out=… cache_w=… cache_r=… cost_usd=…` line to
  `worker.log`, so before/after can be measured with actual numbers. Set `0` for plain-text output.
- **Economy preset documented** — `WCT_MODEL=claude-haiku-4-5` for cost-sensitive users.
- **Settings surface** — `config.example.sh` documents every token-spending feature with a
  «⚠️ витрачає токени» note; README gains a «⚠️ Вартість у токенах» section (plain Ukrainian) with a
  per-feature cost table and how to disable each.
- Hook contract unchanged: stdin JSON, exit 0 on every path, detached double-fork+setsid spawn,
  `CLAUDE_TITLE_GEN` guard, idempotent locks/throttle/change-gate, graceful degradation (a failed or
  empty gen keeps the old card).

## 0.2.0 — 2026-06-03

Hardening pass after a 331-agent adversarial audit (53 confirmed findings). Highlights:

- **Injection — fence breakout closed.** User text is sanitized (collapse `=` runs, neutralize
  ТЕМА:/ЦІЛЬ:/ЗАДАЧА:/ПОПЕРЕДНЯ: labels) and the data fence now uses a per-invocation **nonce**
  marker the input can't predict. Defeats both verbatim-fence breakout and label forgery.
- **Worker no longer orphans.** The `claude -p` call is wrapped in `timeout`/`gtimeout` and an
  `EXIT` trap always releases the lock — a hung/killed gen can't leave a zombie process or wedge
  updates.
- **Throttle is portable + tied to success.** Replaced BSD-only `stat -f %m` with a `stat -f` →
  `stat -c` fallback (the throttle silently never engaged on Linux). Throttle now keys off the
  card's mtime (a real success), not the spawn, so a failed gen can't suppress the card.
- **Atomic mutex.** Lock is an atomic `mkdir` dir with stale-steal, replacing the non-atomic
  `touch` (check-then-touch could double-spawn workers).
- **install.sh** now uses `jq` instead of hardcoded `/usr/bin/python3`, writes settings.json
  atomically (tmp+mv), **merges** statusLine (preserves user `padding`/`refreshInterval`),
  validates JSON before backing up, backs up only on real change, and ships with the execute bit.
- **Privacy & hygiene.** `worker.log` is created `0600` in a `0700` dir and rotates at ~256 KB.
  Control/ANSI bytes are stripped from the card before it reaches the terminal.
- **Portability.** claude-binary ladder now includes Homebrew paths; worker `cd`s to
  `${TMPDIR:-/tmp}`; locale falls back to `C.UTF-8`.
- **goal-keeper** only asks for topic/goal on a real `startup` (not resume/compact/clear).
- **statusline** reads the card in one pass (no torn read); user topic/goal writes are atomic.

## 0.1.0 — 2026-06-03

Initial plugin packaging of the wave-chat-title status card (previously loose
scripts in `~/wave-chat-title/` wired by hand into `settings.json`).

- **Packaged as a Claude Code plugin + local marketplace** — `plugin.json`,
  `marketplace.json`, `hooks/hooks.json` (Stop + SessionStart auto-activate).
- **Portable** — removed hardcoded paths: `claude` binary auto-detected
  (`WCT_CLAUDE_BIN` override → PATH → `~/.local/bin` → bare name); `wct-goal.sh`
  path resolved from the script's own dir; hook commands use `${CLAUDE_PLUGIN_ROOT}`.
- **Two-version seam** — single codebase + optional `config.sh` overlay
  (`WCT_MODEL`, `WCT_THROTTLE_SECONDS`, `WCT_CLAUDE_BIN`); the "for everyone"
  defaults vs a "tuned for me" overlay, no fork.
- **Prompt-injection hardening (carried in)** — the summarizer fences the
  session log as data and ignores instructions inside it; previously a user
  command in chat hijacked the summarizer (it asked for files; the card stopped
  updating).
- **Diagnostics** — every summarizer run logged to `worker.log` (raw output +
  stderr) to separate real failures from injection confusion.
- **`/chat-goal` command** + `install.sh` that wires the (global, single-slot)
  status line and seeds the personal overlay, with a settings.json backup.
