#!/usr/bin/env bash
# design/watch.sh — live preview for the Titulus card layout.
#
# Keeps a few reference frames on screen and redraws them the moment `layout.conf` changes on
# disk — so you can edit the config in your editor and see the effect immediately, without
# touching statusline.sh or running an agent.
#
# No external dependencies (no fswatch/entr — may not be installed): change detection is a plain
# mtime poll, once every 0.5-1s (default 0.7s), using only `stat` + a `[ ]` comparison.
#
# Usage:
#   ./watch.sh                    # watch design/layout.conf (default)
#   ./watch.sh path/to/other.conf # watch a different layout file (e.g. a scratch copy)
#   WCT_WATCH_INTERVAL=0.5 ./watch.sh
#
# Ctrl+C exits cleanly: restores the cursor, no child processes left behind (the only children
# are short-lived `python3 render.py` calls per redraw — none of them outlive this script; the
# `sleep` in the poll loop is the only thing running between redraws, and the INT/TERM trap kills
# the script before another sleep/redraw can start).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

LAYOUT="${1:-layout.conf}"
INTERVAL="${WCT_WATCH_INTERVAL:-0.7}"

if [ ! -f "$LAYOUT" ]; then
  echo "watch.sh: layout file not found: $LAYOUT" >&2
  exit 1
fi

FONT="$HOME/Library/Fonts/TempusGlyphs-Regular.ttf"
if [ ! -f "$FONT" ]; then
  echo "warning: $FONT not found — rounded corners (U+E87E/U+E881) show as tofu/blank." >&2
fi

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

cleanup() {
  printf '\033[?25h'   # restore cursor
  printf '\nwatch.sh: зупинено.\n'
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# Panels shown every redraw: two activity states (calm / busy-with-movement-chips) each at two
# widths (80 = normal, 38 = narrow threshold), so a layout.conf edit's effect on BOTH axes — what
# shows, and what happens when it doesn't fit — is visible at once, no separate command needed.
PANELS=(
  "1:80:спокій, 80 колонок"
  "1:38:спокій, 38 колонок (вузько)"
  "2:80:рух — агенти + coord, 80 колонок"
  "6:38:рух, вузько — вбудований стан 6 (38, agents+coord)"
)

draw() {
  clear
  printf '\033[1mTitulus — живий перегляд картки\033[0m   файл: %s   Ctrl+C — вихід\n' "$LAYOUT"
  printf 'перемальовано: %s   (кожні %ss перевіряється mtime %s)\n\n' "$(date '+%H:%M:%S')" "$INTERVAL" "$LAYOUT"
  for panel in "${PANELS[@]}"; do
    state="${panel%%:*}"
    rest="${panel#*:}"
    width="${rest%%:*}"
    label="${rest#*:}"
    printf '── стан %s — %s ──\n' "$state" "$label"
    if ! python3 render.py --layout "$LAYOUT" --state "$state" --width "$width"; then
      echo "  (помилка рендеру — перевір синтаксис $LAYOUT; попередній кадр лишається дійсним)"
    fi
    echo
  done
  echo "Правила ширини/токенів — дивись коментар на початку $LAYOUT."
  echo "Після правки: python3 render.py --verify && python3 render.py --audit"
  echo "Прев'ю в середовищах (Claude Code реальний / Codex макет): ./preview-env.sh"
}

printf '\033[?25l'   # hide cursor while the preview is live
draw
last="$(mtime "$LAYOUT")"
while true; do
  sleep "$INTERVAL"
  cur="$(mtime "$LAYOUT")"
  if [ "$cur" != "$last" ]; then
    last="$cur"
    draw
  fi
done
