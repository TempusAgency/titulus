# wave-chat-title

A live **status card** for every Claude Code chat. It renders inside the terminal's status line
(the bar at the bottom of the terminal window) and keeps a short summary of what each session is
for, updated automatically in the background as the conversation goes on.

<!--
TODO before publishing: insert an up-to-date ASCII example of the rendered card here, taken from
design/REFERENCE.md once its layout is finalized (an idle-state frame and a busy-state frame).
-->

…plus a **role-keeper**: at session start it asks for the chat's role and remembers what you say,
so the card doesn't have to guess from scratch every time.

The card is produced by a small background agent. By default it summarizes the chat **once** — the
role is derived early and then **frozen** — after which a settled session makes **no further
background calls**. Optional live fields (what's happening right now / what just finished) are
**off by default**, because they cost tokens on every refresh; turn them on in your config file if
you want them. See [Token cost](#token-cost) below.

---

## Install

```bash
# PLUGIN_DIR = the folder containing this README (where you cloned/copied the plugin).

# 1) add this folder as a local marketplace + install the plugin
/plugin marketplace add <PLUGIN_DIR>
/plugin install wave-chat-title@wave-chat-title

# 2) wire the status line (hooks activate automatically; re-run after a plugin UPDATE)
bash <PLUGIN_DIR>/install.sh

# 3) open a new session
```

**Why the separate `install.sh`?** Hooks, commands and skills auto-activate with the plugin. The
**status line is a single global setting** (only one can be active system-wide), so a plugin can
ship the renderer but can't silently claim the slot — `install.sh` opts it in. It copies the
renderer to a stable path (`~/.claude/wave-chat-title/statusline.sh`) and points `settings.json`
there, after backing up whatever was there before.

---

## Requirements

- **Claude Code**, with a terminal that renders its status line (Wave Terminal, iTerm2, Windows
  Terminal, or any modern 24-bit-color terminal).
- **macOS, Linux, or Windows** (on Windows, Claude Code runs the `.sh` scripts through Git Bash
  automatically). The card itself is plain shell + perl + jq, so it runs anywhere those three
  exist.
- **`jq`** — required, used to read Claude Code's JSON. Usually needs a separate install
  (`brew install jq` / `apt-get install jq` / `winget install jqlang.jq`).
- **perl** (core module `Text::Wrap`) — for character-aware wrapping (handles non-Latin text
  correctly). Preinstalled on macOS/Linux; comes with Git for Windows.
- **A font with the extra corner glyphs is optional.** The card's rounded/cut corners use a
  handful of custom glyph codepoints from a small companion font (`TempusGlyphs`). If that font
  isn't installed, the terminal falls back to plain box-drawing corners (`┌ ┐ └ ┘`) — the card
  still renders correctly, just with square corners instead of the styled ones.

Run the built-in doctor anytime to see exactly what's missing on your machine:

```bash
bash scripts/doctor.sh
```

`install.sh` runs this check automatically and refuses to wire the status line until everything
required is present. Full platform-by-platform instructions (including the Windows/Git Bash notes)
are in [REQUIREMENTS.md](REQUIREMENTS.md).

---

## What's in the box

| Piece | Event | What it does |
|---|---|---|
| `scripts/topic-update.sh` | **Stop** hook | Decides what (if anything) needs generating; spawns the detached summarizer only when there is work (never blocks the UI). Change-gated + throttled. Skips entirely once the role is frozen and the live fields are off. |
| `scripts/topic-gen-worker.sh` | (spawned) | The background `claude -p` summarizer. Writes the card cache and logs real token usage. |
| `scripts/goal-prompt.sh` | **SessionStart** hook | Injects the role-keeper behavior; surfaces a user-set role. |
| `scripts/wct-goal.sh` | (helper) | Persists a user-set role (wins over the auto-summary). |
| `statusline.sh` | status line | Renders the card, word-wrapped for narrow terminal widths. |
| `commands/chat-goal.md` | `/wave-chat-title:chat-goal` | Pin this chat's role by hand. |

> Plugin commands are namespaced: invoke it as `/wave-chat-title:chat-goal topic "<text>"`.
> Validate the bundle anytime with `/plugin validate <PLUGIN_DIR>`.

State lives in two places:
- **Ephemeral card cache** — `${TMPDIR}/wave-chat-title/<session>.ai` (the OS may clear `TMPDIR`
  on reboot; that's fine, it regenerates).
- **Persistent user data** — `~/.claude/wave-chat-title/` (user-set role overrides, `config.sh`,
  `worker.log`). Survives reboots.

---

## Configuration

Defaults ship sane for everyone. Your personal tuning lives in a separate overlay file, so there's
no fork and no duplicated plugin — just one small config file:

```bash
# install.sh seeds this from config.example.sh the first time it runs
$EDITOR ~/.claude/wave-chat-title/config.sh
```

Key knobs (all documented inline in `config.example.sh`):

| Variable | What it controls | Default |
|---|---|---|
| `WCT_DISABLE` | Kill switch — stops all background generation and API calls | off |
| `WCT_TASK_FIELD` | Live "what's happening now" line | off (costs tokens) |
| `WCT_PREVIOUS_FIELD` | Live "what just finished" line (needs `WCT_TASK_FIELD`) | off (costs tokens) |
| `WCT_MODEL` | Model used by the background summarizer | `claude-sonnet-4-6` |
| `WCT_THROTTLE_SECONDS` | Minimum interval between live-field refreshes | 600 (10 min) |
| `WCT_NAME_INPUT_CHARS` / `WCT_RECENT_INPUT_CHARS` | How much chat text gets sent to the model per call | 4000 / 6000 |
| `WCT_LOG_USAGE` | Logs real input/output/cost per call to `worker.log` | on |
| `WCT_CLAUDE_BIN` | Explicit path to the `claude` binary, if it's not on the hook's `PATH` | auto-detected |

---

## Hardened against prompt injection

The summarizer reads your recent **user messages** — which often contain commands ("fix
launcher.py"). Fed raw, the background agent would try to *obey* them instead of summarizing: it
attempts to act, hits its disabled tools, and surfaces a confusing prompt — while the card silently
fails to update. This plugin fences that text as data and instructs the agent to ignore any
instructions inside it. See `scripts/topic-update.sh` and the system prompt in
`scripts/topic-gen-worker.sh`.

Every run is recorded to `~/.claude/wave-chat-title/worker.log` (raw output + stderr) so genuine
failures (API down, etc.) are distinguishable from injection confusion.

---

## Token cost

The background card generator makes `claude -p` calls — real tokens on your account, multiplied by
however many sessions you have open at once. Here's what costs what, and how to turn it off:

| What | When it spends tokens | Roughly how much | How to disable / tune |
|---|---|---|---|
| **Role** (the core summary) | **Once**, near the start of the session (first ~10 messages or 5 minutes), then **frozen** | ~1 call per session | `WCT_NAME_INPUT_CHARS` — smaller input |
| **Task** (live "what's happening now") | Every ~10 minutes while the session is open — a **live** field | N calls/day × open sessions | **Off by default.** Enable with `WCT_TASK_FIELD=1`. |
| **Previous** (live "what just finished") | Alongside Task | Slightly larger output per call | **Off by default.** Enable with `WCT_PREVIOUS_FIELD=1` (needs `WCT_TASK_FIELD=1`). |

**With defaults, once the role has frozen, the session makes zero further background calls** —
until you turn a live field on. That's the whole optimization: an earlier version of this plugin
sent the *entire* chat transcript on every turn; this one sends one small call per session.

**See the actual numbers:** every call logs a `USAGE … in=… out=… cost_usd=…` line to
`~/.claude/wave-chat-title/worker.log` (on by default, `WCT_LOG_USAGE=1`):

```bash
grep USAGE ~/.claude/wave-chat-title/worker.log
```

**Full stop:** set `WCT_DISABLE=1` in `~/.claude/wave-chat-title/config.sh` to instantly stop all
generation. This also acts as a privacy opt-out — no chat text leaves your machine via the
background summarizer while it's set.

---

## Notes & limits

- **The background summary needs API access to Claude.** If it's rate-limited, the card keeps its
  last value — it degrades gracefully rather than breaking.
- The card updates on **Stop** (end of each turn). Live fields, if enabled, are throttled to once
  per `WCT_THROTTLE_SECONDS` (default 10 min).
- Designed for, but not limited to, Wave Terminal. Any terminal that renders the Claude Code status
  line works.

## Uninstall

```bash
/plugin uninstall wave-chat-title@wave-chat-title    # removes hooks/commands
# then remove the "statusLine" key from ~/.claude/settings.json
# (or restore it from the .bak-* backup install.sh made)
```

## License

MIT — see [LICENSE](LICENSE).
