# wave-chat-title

A live **status card** for every Claude Code chat. At the bottom of your terminal you see, per session:

```
● Роль: <who this session is / what it is for>
▸ Задача: <what's happening now>
◃ Попередня: <what just finished>
⎇ branch · контекст 57% · ✻ 9f952440
```

…plus a **role-keeper**: at session start it asks for the chat's role and remembers what you say.

The card is produced by a small background agent. By default it summarizes the chat **once** — the **Name** (role) is derived early and then **frozen** — after which a settled session makes **no further background calls**. The live **Task** / **Previous** lines are **off by default** (they cost tokens on every refresh); turn them on in `config.sh` if you want them. See [«⚠️ Вартість у токенах»](#-вартість-у-токенах--token-cost).

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

> Requires `jq` (the hooks already use it). On this machine `<PLUGIN_DIR>` is `/Users/tempus/wave-chat-title-plugin`.

**Why the separate `install.sh`?** Hooks, commands and skills auto-activate with the plugin. The **status line is a single global setting** (only one can be active system-wide), so a plugin can ship the renderer but can't silently claim the slot — `install.sh` opts it in. It copies the renderer to a stable path (`~/.claude/wave-chat-title/statusline.sh`) and points `settings.json` there, after backing the file up.

---

## What's in the box

| Piece | Event | What it does |
|---|---|---|
| `scripts/topic-update.sh` | **Stop** hook | Decides what (if anything) needs generating; spawns the detached summarizer only when there is work (never blocks the UI). Change-gated + throttled. Skips entirely once the Name is frozen and Task/Previous are off. |
| `scripts/topic-gen-worker.sh` | (spawned) | The background `claude -p` summarizer. Writes the card cache and logs real token `usage`. |
| `scripts/goal-prompt.sh` | **SessionStart** hook | Injects the role-keeper behavior; surfaces a user-set role. |
| `scripts/wct-goal.sh` | (helper) | Persists a user-set role (wins over the auto-summary). |
| `statusline.sh` | status line | Renders the card, word-wrapped for narrow Wave blocks. |
| `commands/chat-goal.md` | `/wave-chat-title:chat-goal` | Pin this chat's role by hand. |

> Plugin commands are namespaced: invoke it as `/wave-chat-title:chat-goal topic <text>`. Validate the bundle anytime with `/plugin validate <PLUGIN_DIR>`.

State lives in two places:
- **Ephemeral card cache** — `${TMPDIR}/wave-chat-title/<session>.ai` (macOS wipes TMPDIR; that's fine, it regenerates).
- **Persistent user data** — `~/.claude/wave-chat-title/` (user-set role overrides, `config.sh`, `worker.log`). Survives reboots.

---

## Two versions, one codebase ("файл-заточка")

The plugin ships sane **defaults** = the *for-everyone* build. Your **personal** tuning lives in a separate overlay file, so there is no fork and no duplicate skill:

```bash
# edit your overlay (install.sh seeds it from config.example.sh)
$EDITOR ~/.claude/wave-chat-title/config.sh
```

Knobs: `WCT_MODEL`, `WCT_THROTTLE_SECONDS`, `WCT_CLAUDE_BIN`, plus the token-cost flags
`WCT_TASK_FIELD` / `WCT_PREVIOUS_FIELD` (live fields, off by default), the input caps
`WCT_NAME_INPUT_CHARS` / `WCT_RECENT_INPUT_CHARS`, and `WCT_LOG_USAGE`. Every token-spending knob is documented in
`config.example.sh` with a «⚠️ витрачає токени» note. Both Stop-hook scripts source this file if present.

---

## Hardened against prompt injection

The summarizer reads your recent **user messages** — which often contain commands ("fix launcher.py"). Fed raw, the agent would *obey* them instead of summarizing: it tries to act, hits its disabled tools, and asks you for the file via a popup — while the card silently fails to update. This plugin **fences that text as data** and tells the agent to ignore any instructions inside it. See `scripts/topic-update.sh` and the system prompt in `scripts/topic-gen-worker.sh`.

Every run is recorded to `~/.claude/wave-chat-title/worker.log` (raw output + stderr) so genuine failures (API down) are distinguishable from injection confusion.

---

## ⚠️ Вартість у токенах / token cost

Фоновий генератор картки робить виклики `claude -p` — це **реальні токени на твоєму рахунку**,
і вони множаться на кількість одночасних сесій. Ось що скільки коштує і як це вимкнути:

| Що | Коли витрачає токени | Приблизний масштаб | Як вимкнути / налаштувати |
|---|---|---|---|
| **НАЗВА** (ядро, роль) | **Один раз** на старті сесії (перші ~10 повідомлень або 5 хв), потім **заморожується** | ~1 виклик на сесію, вхід ≤ `WCT_NAME_INPUT_CHARS` (4000 симв. за замовч.) | `WCT_NAME_INPUT_CHARS` — менший вхід. |
| **ЗАДАЧА** (`▸ Задача`) | **Кожні 10 хв**, поки сесія відкрита — ЖИВЕ поле | N викликів/день × сесій (саме це раніше і палило токени) | **Вимкнено за замовч.** Увімкнути: `WCT_TASK_FIELD=1`. |
| **ПОПЕРЕДНЯ** (`◃ Попередня`) | разом із ЗАДАЧЕЮ | трохи більший вихід на виклик | **Вимкнено.** Увімкнути: `WCT_PREVIOUS_FIELD=1` (потребує `WCT_TASK_FIELD=1`). |

**Головне:** з дефолтними налаштуваннями, **щойно НАЗВА заморозилась, сесія більше не робить
жодного фонового виклику** — 0 токенів, поки ти не вмикаєш живі поля. Це і є оптимізація:
раніше плагін пересилав **увесь чат на кожен Stop** (≈760K токенів/день за ~49 сесій), тепер —
один невеликий виклик на сесію.

**Як подивитися фактичні цифри:** кожен виклик пише рядок `USAGE … in=… out=… cost_usd=…` у
`~/.claude/wave-chat-title/worker.log` (увімкнено `WCT_LOG_USAGE=1`). Подивись реальні токени:

```bash
grep USAGE ~/.claude/wave-chat-title/worker.log
```

**Повний стоп:** `WCT_DISABLE=1` у `~/.claude/wave-chat-title/config.sh` миттєво глушить усю
генерацію — це водночас і privacy-opt-out: жоден текст чату не йде в API.

Усі прапорці задокументовані в `config.example.sh` (із поміткою «⚠️ витрачає токени» на кожному
платному).

---

## Notes & limits

- **Background summary needs the Claude API.** If it's rate-limited, the card keeps its last value (it degrades, it doesn't break).
- **Cost & kill switch.** With defaults, generation is a one-time **Name** call per session, then frozen — see [«⚠️ Вартість у токенах»](#-вартість-у-токенах--token-cost). Set `WCT_DISABLE=1` in `~/.claude/wave-chat-title/config.sh` to stop all generation instantly.
- The card updates on **Stop** (end of each turn). Live fields (if enabled) are throttled to once / 10 min by default (`WCT_THROTTLE_SECONDS`).
- Designed for, but not limited to, Wave Terminal. Any terminal that shows the Claude Code status line works.

## Uninstall

```bash
/plugin uninstall wave-chat-title@wave-chat-title    # removes hooks/commands
# then remove the "statusLine" key from ~/.claude/settings.json (or restore a .bak-* )
```
