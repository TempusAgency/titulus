# wave-chat-title — personal overlay ("файл-заточка").
#
# THE TWO-VERSION MODEL, with ONE codebase:
#   • The plugin scripts ship sane DEFAULTS → the "for everyone" version.
#   • This file (copied to ~/.claude/wave-chat-title/config.sh) overrides them
#     → the "tuned for me" version. No fork, no duplicate skill — just a config seam.
#
# install.sh copies this to ~/.claude/wave-chat-title/config.sh if none exists.
# Both topic-update.sh and topic-gen-worker.sh source it. Plain shell `KEY=value`.
# Everything here is OPTIONAL — delete a line to fall back to the default.

# ============================================================================
#  ⚠️ ВАРТІСТЬ У ТОКЕНАХ — прочитай перед тим, як щось вмикати
# ============================================================================
# Кожен фоновий виклик `claude -p` — це РЕАЛЬНІ токени (вхід+вихід) на твій рахунок,
# і він множиться на кількість одночасних сесій. Дефолти нижче зроблені МАКСИМАЛЬНО
# дешевими: НАЗВА і ЦІЛЬ генеруються ОДИН раз на старті сесії й заморожуються; ЗАДАЧА
# і ПОПЕРЕДНЯ ВИМКНЕНІ. Коли НАЗВА+ЦІЛЬ заморожені й ЗАДАЧА/ПОПЕРЕДНЯ вимкнені — сесія
# більше НЕ робить жодного фонового виклику (0 токенів). Усе, що ти вмикаєш нижче з
# поміткою «⚠️ витрачає токени», повертає періодичні виклики.

# --- Master kill switch -----------------------------------------------------
# Set to any non-empty value to STOP all background generation (no model calls,
# no goal-keeper). The card keeps whatever it last had. Cost + privacy opt-out:
# when set, no chat content leaves your machine via the background summarizer.
# WCT_DISABLE=1

# --- ЗАДАЧА (TASK) field --------- ⚠️ ВИТРАЧАЄ ТОКЕНИ (вимкнено за замовчуванням) -
# Рядок «▸ Задача: …» — що відбувається ЗАРАЗ. Це ЖИВЕ поле: оновлюється фоновим
# викликом моделі КОЖЕН раз, коли спливає тротл (раз на 10 хв на активну сесію),
# поки сесія відкрита. Саме воно тримало старий дрейн. Увімкни, лише якщо реально
# користуєшся цим рядком. Default: 0 (off).
# WCT_TASK_FIELD=1

# --- ПОПЕРЕДНЯ (PREVIOUS) field -- ⚠️ ВИТРАЧАЄ ТОКЕНИ (вимкнено; потребує TASK) ----
# Рядок «◃ Попередня: …» — дія перед поточною задачею. Працює лише разом з
# WCT_TASK_FIELD=1 (без TASK ігнорується). Трохи більший вихід на кожен виклик.
# Default: 0 (off).
# WCT_PREVIOUS_FIELD=1

# --- ЦІЛЬ (GOAL) refresh policy --------------------------------------------
# once     = згенерувати ЦІЛЬ ОДИН раз на старті, далі заморозити (НАЙДЕШЕВШЕ, дефолт)
# periodic = ⚠️ ВИТРАЧАЄ ТОКЕНИ: перегенеровувати ЦІЛЬ кожні WCT_GOAL_REFRESH_SECONDS
# off      = взагалі не генерувати ЦІЛЬ (перший рядок картки візьме НАЗВУ)
# WCT_GOAL_REFRESH=once
# WCT_GOAL_REFRESH_SECONDS=3600     # лише для periodic; default 3600 (1 год)

# --- Input character caps (чим менше — тим менше токенів на виклик) ---------
# Скільки символів чату слати моделі. ЦІЛЬ береться з ПОЧАТКУ чату (там намір).
# WCT_GOAL_INPUT_CHARS=12000        # було 40000 (увесь чат) — тепер раз і дешевше
# WCT_NAME_INPUT_CHARS=4000         # перші повідомлення → НАЗВА
# WCT_RECENT_INPUT_CHARS=6000       # останні повідомлення → ЗАДАЧА/ПОПЕРЕДНЯ (лише якщо ввімкнено)

# --- Real token-usage logging ----------------------------------------------
# Пише фактичні input/output/cost кожного виклику у worker.log (рядок «USAGE …»),
# щоб міряти до/після реальними числами. Накладні мізерні (один jq). Default: 1 (on).
# Постав 0, щоб вимкнути (тоді виклик іде звичайним текстом, без рядка USAGE).
# WCT_LOG_USAGE=1

# --- Model used by the background summarizer -------------------------------
# Cheaper/faster vs richer. Default: claude-sonnet-4-6.
# Економний пресет: Haiku помітно дешевший за Sonnet на тій самій якості NAME/GOAL.
# WCT_MODEL="claude-sonnet-4-6"
# WCT_MODEL="claude-haiku-4-5"      # ← економний варіант

# --- How often the card may regenerate (seconds) --- ⚠️ нижче = більше токенів ---
# The Stop hook throttles to this. Стосується лише ЖИВИХ полів (TASK/PREVIOUS) та
# periodic-цілі; заморожені NAME/GOAL цим не керуються. Default: 600 (10 min).
# WCT_THROTTLE_SECONDS=600

# --- Explicit path to the `claude` binary ----------------------------------
# Only needed if `claude` is not on the hook's PATH and not at ~/.local/bin/claude.
# WCT_CLAUDE_BIN="$HOME/.local/bin/claude"

# --- (Reserved for the personal build — NOT yet wired) ---------------------
# Placeholder for the future personal-only feature: push this session's card to
# the team coord branch. Declared here so the design is visible; no code reads it
# yet. The public plugin stays thin; the personal build will consume this.
# WCT_COORD_PUSH=0
