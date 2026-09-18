#!/usr/bin/env bash
# wave-chat-title — SessionStart hook. Injects behavior so Claude (1) on a FRESH start asks the
# user for the branch TOPIC and GOAL, (2) surfaces a user-set topic/goal as authoritative,
# (3) gently keeps the user on-goal. stdout = session context.
set -uo pipefail

# don't run inside the background topic-summary subprocess
if [ -n "${CLAUDE_TITLE_GEN:-}" ]; then exit 0; fi

# personal overlay + master kill switch (consistent with topic-update.sh)
WCT_CONFIG="${WCT_CONFIG:-$HOME/.claude/wave-chat-title/config.sh}"
[ -f "$WCT_CONFIG" ] && . "$WCT_CONFIG"
[ -n "${WCT_DISABLE:-}" ] && exit 0

# SessionStart delivers JSON on stdin: {session_id, source, ...}. `source` ∈ startup|resume|
# compact|clear. We only nudge "ask for topic/goal" on a genuine startup, not on resume/compact.
INPUT="$(cat 2>/dev/null || true)"
source_kind="$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)"
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$sid" ] && sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$sid" ] && exit 0

dir="$HOME/.claude/wave-chat-title"   # PERSISTENT — survives reboot / TMPDIR cleanup
# portable path to wct-goal.sh: this script's own dir (works under ${CLAUDE_PLUGIN_ROOT} or anywhere)
WCT="$(cd "$(dirname "$0")" && pwd)/wct-goal.sh"
t=""; g=""
[ -s "$dir/$sid.topic" ] && t="$(cat "$dir/$sid.topic")"
[ -s "$dir/$sid.goal" ]  && g="$(cat "$dir/$sid.goal")"

{
echo "🎯 ХРАНИТЕЛЬ РОЛІ Й ЦІЛІ — постійна поведінка для цієї гілки термінала (Claude-сесії):"
if [ -n "$t" ] || [ -n "$g" ]; then
  [ -n "$t" ] && echo "• Роль (задана користувачем): «$t»."
  [ -n "$g" ] && echo "• Ціль (задана користувачем, ФІКСОВАНА): «$g». Тримай її в голові, не переписуй."
elif [ -z "$source_kind" ] || [ "$source_kind" = "startup" ]; then
  echo "• ПЕРШЕ у новій гілці: одним коротким питанням спитай користувача про РОЛЬ і ЦІЛЬ цієї сесії:"
  echo "    – РОЛЬ = хто ця сесія / для чого (формат «Слово. уточнення»: перше ОДНЕ слово — Rework, Дослідник, Фікс, Рефактор; далі крапка й коротке уточнення)."
  echo "    – ЦІЛЬ = чого саме хочемо тут досягти (коротко; вона фіксується й далі не дрейфує)."
fi
cat <<EOF
• Коли користувач проговорює роль чи ціль СЛОВАМИ — це авторитетні значення, збережи їх ОДРАЗУ (вони перекривають авто-аналіз і йдуть у картку):
    роль: "$WCT" topic "<Слово. уточнення>"
    ціль: "$WCT" set   "<коротка ціль>"
  Роль ОБОВ'ЯЗКОВО у форматі «Слово. уточнення» (одне слово, крапка, коротко). Ціль — максимально коротко.
• Якщо ролі не названо — у картці перша строка візьме ЦІЛЬ. Якщо користувач одразу почав працювати, не наполягай: роль/ціль/задачі визначить авто-аналіз (теж у форматі «Слово. уточнення»).
• Слідкуй за контекстом, як людина. Якщо повідомлення користувача НЕ стосується цілі — м'яко попередь: нагадай ціль, зазнач, що це поза нею, і поясни ЧОМУ. Не блокуй, дай вибір. Ціль свідомо змінюють лише командою — авто-аналіз її НЕ чіпає.
EOF
}
