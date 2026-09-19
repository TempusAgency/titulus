#!/usr/bin/env bash
# design/preview-env.sh — the Titulus card as it actually appears in the two places the user
# runs Claude: Claude Code (a REAL render, its real constraints) and Codex CLI (checked on this
# machine — no native custom-statusline mechanism exists, so this is a clearly labeled MOCKUP).
#
# Usage:
#   ./preview-env.sh claude   # Claude Code panel only
#   ./preview-env.sh codex    # Codex CLI panel only
#   ./preview-env.sh          # both, one after another (default)
#
# ---------------------------------------------------------------------------
# Codex finding (checked, not guessed):
#   ~/.codex/config.toml has:
#     [tui]
#     status_line = ["model-with-reasoning", "current-dir", "run-state", "permissions",
#                     "approval-mode", "context-used", "context-window-size", "used-tokens", ...]
#   That is a FIXED ENUM of built-in widgets you pick and order — not a hook that runs an
#   arbitrary command and prints arbitrary text, the way Claude Code's `statusLine.command` does.
#   `codex --help` and `codex doctor` show no "custom status line" / "statusline command" option.
#   An unrelated, already-installed local project independently reached the same conclusion:
#   ~/plugins/titulus-codex/README.md, section "Current Boundary": "Codex does not currently
#   expose a Claude-style external statusline renderer... I did not find a reliable external
#   renderer API in the local Codex build." Two independent checks agree.
#   CONCLUSION: no native mechanism → the Codex panel below is a MOCKUP, labeled as such.
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mode="${1:-both}"

hr() { printf '%*s\n' "${1:-80}" '' | tr ' ' '─'; }

show_claude() {
  echo
  printf '\033[1m███ CLAUDE CODE — реальний рендер, реальні обмеження ███\033[0m\n'
  echo "Механізм: settings.json → statusLine.command (наш statusline.sh). Це СПРАВЖНІЙ рендер —"
  echo "та сама картка, яку бачить бойова сесія, не макет."
  echo
  echo "Обмеження, які диктує сам Claude Code (не наш вибір):"
  echo "  • Ширина: \$COLUMNS від CC — точна й реагує на ресайз у режимі Default (block/термінал)."
  echo "    У Fullscreen TUI (Tempus Launcher) ширина НЕ ресайзиться — відкрита проблема (див."
  echo "    CLAUDE.md цього репо, розділ \"Відкриті питання\"). Нижче — типова ширина Default-блоку"
  echo "    (67) і повна ширина вікна (102)."
  echo "  • Частота перемальовування: НЕ миттєва — тільки на нове повідомлення + таймер"
  echo "    refreshInterval (300с у нашому install.sh; глобальна настройка ~/.claude/settings.json,"
  echo "    вартість ×кількість живих сесій — нижче за 30 заборонено без явного апруву). Ресайз"
  echo "    \"під мишку\" підхопиться лише на наступному рендері, не миттєво."
  echo
  echo "── Default-блок, 67 колонок, у спокої ──"
  python3 render.py --state 1 --width 67
  echo
  echo "── Default-блок, 102 колонки, під час роботи (агенти + coord) ──"
  python3 render.py --state 2 --width 102
  echo
}

show_codex() {
  echo
  printf '\033[1;33m███ CODEX CLI — МАКЕТ, нативної підтримки немає (перевірено) ███\033[0m\n'
  echo "~/.codex/config.toml → [tui] status_line — фіксований список вбудованих токенів"
  echo "(model-with-reasoning, current-dir, run-state, context-used, ...), а не команда, що"
  echo "друкує довільний текст. Установлений $(codex --version 2>/dev/null || echo 'Codex CLI')."
  echo "codex --help / codex doctor не показують опції кастомного статус-рядка."
  echo "Незалежне підтвердження: ~/plugins/titulus-codex/README.md, розділ \"Current Boundary\"."
  echo
  echo "Нижче — як картка виглядала б, ЯКЩО вставити її текстом у вікно Codex. Це не справжній"
  echo "статус-рядок Codex (такого API немає) — це те, що фактично робить ~/plugins/titulus-codex"
  echo "сьогодні: окрема sidecar-панель / Wave frame:text, а не вбудований рендер Codex."
  echo
  hr 80
  echo "▌ Codex CLI — вікно сесії"
  hr 80
  echo "▌ (тут — звичайний діалог Codex; картка нижче НЕ частина TUI Codex, це окрема панель"
  echo "▌  поруч/під, як у titulus-codex sidecar)"
  echo
  python3 render.py --state 1 --width 78
  echo
  echo "Для порівняння — рядок статусу, який Codex РЕАЛЬНО малює сам (з config.toml):"
  printf '  \033[2m'
  python3 - "$HOME/.codex/config.toml" <<'PYEOF'
import sys, re
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    print("(config.toml не знайдено)")
    sys.exit()
m = re.search(r'status_line\s*=\s*\[(.*?)\]', text, re.S)
if m:
    items = [x.strip().strip('"') for x in m.group(1).split(",") if x.strip()]
    print(" | ".join(items))
else:
    print("(status_line не налаштовано в config.toml)")
PYEOF
  printf '\033[0m'
  hr 80
  echo
}

case "$mode" in
  claude) show_claude ;;
  codex)  show_codex ;;
  both|*) show_claude; show_codex ;;
esac
