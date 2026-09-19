# Changelog

## Unreleased — 2026-09-19 — порогова колірна індикація CTX/5h/7d

`◷ CTX N%`, `◴ 5h N%`, `◴ 7d N%` тепер фарбуються за порогами замість завжди-приглушеного
сірого: <40% — без змін (сірий), ≥40% — яскравий білий, ≥50% — жовтий, ≥60% — терракота
(вже наявний акцент палітри), ≥80% — червоний. Фарбується весь токен (глиф+лейбл+число), не
тільки число — так чіп читається одним поглядом і не робить рядок строкатим; решта id-рядка
(глиф+id сесії, розділювачі) лишається сірою, як була.

Пороги і кольори **зашиті в код** (не в `layout.conf`) — за прямою вимогою: користувач
відхилив ідею конфігурованих порогів («не треба мені налаштування — зроби як я сказав і
все»). Однакова логіка в обох рендерах:
- `design/render.py` — `pct_color()` + `RGB_PCT_*` константи, нова `content_row_spans()` для
  розфарбовки токенів усередині одного рядка (замість одного кольору на весь рядок).
- `statusline.sh` — той самий поріг у вже наявному perl-проході (`render_text()`): нова
  `pct_color()` sub + `content_row_multi()`. Жодних нових підпроцесів — порівняння чисел і
  розфарбовка залишаються всередині того самого одного perl-виклику на рендер.

Геометрія не змінена: `render.py --verify` 7/7, `--audit` 0 порушень, перевірено на
системному bash 3.2.57 (macOS) реальним запуском з synthetic JSON на 5 рівнях (15/41/55/65/85%).

## Unreleased — 2026-09-19 — пісочниця для розкладки картки (не чіпає живий вигляд)

Живий `layout.conf` лишається тим, що читає бойовий `statusline.sh` — його НІХТО не редагує
напряму більше. Розкладку тепер правлять в окремому файлі-копії.

- **`design/layout.sandbox.conf`** — нова копія `layout.conf`. Тут можна експериментувати з
  розкладкою, нічого не ламаючи в живій картці.
- **`design/watch.sh`** — за замовчуванням тепер дивиться на `layout.sandbox.conf` (не на
  `layout.conf`). У шапці прев'ю явно видно, який файл показано: `● ПІСОЧНИЦЯ` (безпечно
  редагувати) чи `● БОЙОВИЙ` (те, що бачить живий statusline.sh просто зараз, тільки читання).
  Виклик з аргументом (`./watch.sh layout.conf`) і далі працює як read-only прев'ю будь-якого
  файлу розкладки.
- **`design/apply.sh`** (нове) — переносить `layout.sandbox.conf` → `layout.conf`. Спочатку
  прогонить `render.py --layout layout.sandbox.conf --verify` і `--audit` — якщо хоч один не
  пройшов, `layout.conf` НЕ чіпає і друкує причину. Якщо пройшли — бекапить поточний `layout.conf`
  у `layout.conf.bak-<timestamp>` (той самий gitignored `*.bak-*` конвент, що й решта репо), тоді
  копіює пісочницю в бойовий. `--dry-run` — тільки перевірка, нічого не чіпає.
- **`design/rollback.sh`** (нове) — повертає `layout.conf` з останнього бекапу `apply.sh`
  (`--list` показує всі, `--yes` пропускає підтвердження). Перед відкатом теж робить бекап
  поточного стану — можна скасувати і сам відкат.
- `statusline.sh` не змінено НІ на символ (перевірено побайтовим порівнянням виводу до/після на
  тестовому JSON) — і далі читає бойовий `design/layout.conf` за тим самим ланцюжком резолюції,
  що й раніше.

## Unreleased — 2026-09-16 — функцію ЦІЛЬ (GOAL) видалено

Картка тепер тримає РОЛЬ (перший рядок) + опційні ЗАДАЧА / ПОПЕРЕДНЯ. Рядок «◎ Ціль» більше
не рендериться, фоновий воркер його не генерує, SessionStart-хук більше не веде goal-keeper.

**Ключове інженерне рішення: нічого не перенумеровано.** У трьох місцях із позиційною
залежністю лишені порожні заглушки.

- **`statusline.sh`** — блок `@b[2]` залишено як порожній `field("","")`. Шляхи друкуються через
  `${tb[$((5 + di))]}`, тож видалення елемента зсунуло б індекси й замість шляхів показалась би Задача.
- **Формат кешу `${TMPDIR}/wave-chat-title/<sid>.ai`** — лишається ТРИРЯДКОВИМ; перший рядок завжди
  порожній і читається у змінну-смітник. Старі файли з непорожнім першим рядком просто
  ігноруються (зворотна сумісність).
- **`scripts/topic-update.sh` / `topic-gen-worker.sh`** — знято `regen_goal`, `goallock`, зріз «початок
  чату», спец `ЦІЛЬ:` у промпті та парсинг `newgoal`/`oldgoal`. **14 позиційних аргументів
  воркера не перенумеровані** — позиції 4 (`goallock`) і 6 (`regen_goal`) передаються порожніми.
- **`scripts/wct-goal.sh`** — підкоманду `set` прибрано; лишились `topic` / `get` / `clear` (роль).
  Назву файла й команди `/wave-chat-title:chat-goal` навмисно НЕ перейменовано.
- **`scripts/goal-prompt.sh`** — «ХРАНИТЕЛЬ РОЛІ Й ЦІЛІ» → «ХРАНИТЕЛЬ РОЛІ»; прибрано goal-keeper
  і застарілий фолбек «якщо ролі не названо — картка візьме ЦІЛЬ» (такого коду ніколи не було).
- **Конфіг** — вилучено `WCT_GOAL_REFRESH`, `WCT_GOAL_REFRESH_SECONDS`, `WCT_GOAL_INPUT_CHARS`
  (більше нічим не читаються).
- Користувацькі файли `~/.claude/wave-chat-title/*.goal` НЕ видаляються — просто більше не читаються.
- Історичні записи нижче та `docs/AUDIT-*` / `docs/OPTIMIZATION-HANDOFF-*` навмисно НЕ переписані.

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
