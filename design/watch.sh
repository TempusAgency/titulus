#!/usr/bin/env bash
# design/watch.sh — live preview for the Titulus card layout.
#
# Keeps a few reference frames on screen and redraws them the moment `layout.conf` changes on
# disk — so you can edit the config in your editor and see the effect immediately, without
# touching statusline.sh or running an agent.
#
# No external dependencies (no fswatch/entr — may not be installed): change detection is a plain
# mtime poll, once every 0.5-1s (default 0.7s), using only `stat` + a `[ ]` comparison. Window
# width is read with `tput cols` (part of the base OS terminfo toolset, same tier as `stat`) —
# see WIDTH-AWARE REDRAW below.
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
#
# WIDTH-AWARE REDRAW (fix — a real Wave side panel is ~45 columns wide; a fixed 80-column panel
# there just wraps mid-line, right edge gone, and looks "broken" even though the card itself is
# fine at 38 columns on the SAME screen — the panel set was lying about what actually fits):
#   - Window width is read FRESH every redraw with `tput cols` (falls back to $COLUMNS, then 80).
#   - Only panels that actually FIT the current window are drawn. A candidate wider than the
#     window prints a one-line "doesn't fit, resize" note instead of a truncated/wrapped panel.
#   - The candidate set is 80 (normal reference) / 38 (narrow threshold) / the CURRENT window
#     width itself — deduplicated, so if the window happens to be exactly 80 or 38 it is not
#     shown twice. The current-width panel is the most useful one: it shows exactly how the card
#     will look right where you're looking at it.
#   - A resize while watch.sh is running (no layout.conf edit) also triggers a redraw now — the
#     poll loop compares BOTH the layout file's mtime and the terminal width every tick, not
#     mtime alone.
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

# Actual terminal width, read fresh on demand (see WIDTH-AWARE REDRAW above). `tput cols` queries
# the terminal directly and reacts to a live resize; $COLUMNS is the fallback for the rare case
# tput is missing/fails (e.g. no controlling terminal) — same fallback chain statusline.sh itself
# uses for the production card.
term_width() {
  local w=""
  if command -v tput >/dev/null 2>&1; then
    w="$(tput cols 2>/dev/null)"
  fi
  case "$w" in ''|*[!0-9]*) w="";; esac
  if [ -z "$w" ]; then
    w="${COLUMNS:-80}"
    case "$w" in ''|*[!0-9]*) w=80;; esac
  fi
  printf '%s' "$w"
}

cleanup() {
  printf '\033[?25h'   # restore cursor
  printf '\nwatch.sh: зупинено.\n'
}
trap cleanup EXIT
trap 'exit 0' INT TERM

draw() {
  clear
  local tw; tw="$(term_width)"
  printf '\033[1mTitulus — живий перегляд картки\033[0m   файл: %s   Ctrl+C — вихід\n' "$LAYOUT"
  printf 'перемальовано: %s   (кожні %ss: mtime %s + ширина вікна)   вікно: %s кол.\n\n' \
    "$(date '+%H:%M:%S')" "$INTERVAL" "$LAYOUT" "$tw"

  # Candidate panel widths, in this preference order: 80 (normal reference) / 38 (narrow
  # threshold, where role/place start wrapping) / the window's OWN current width (the most
  # useful one — "what it looks like right here"). Deduplicated below so a window that happens
  # to BE 80 or 38 columns doesn't get the same panel twice.
  local -a cand_w=(80 38 "$tw")
  local -a cand_label=("80 колонок (норма)" "38 колонок (вузький поріг)" "поточне вікно")
  local -a seen=()
  local i w lbl dup s already
  for i in 0 1 2; do
    w="${cand_w[$i]}"; lbl="${cand_label[$i]}"
    already=0
    for s in ${seen[@]+"${seen[@]}"}; do [ "$s" = "$w" ] && already=1 && break; done
    [ "$already" = 1 ] && continue
    seen+=("$w")

    if [ "$w" -gt "$tw" ]; then
      printf -- '── %s (%s) — НЕ вміщається у вікно (зараз %s) — розтягни вікно ──\n\n' "$lbl" "$w" "$tw"
      continue
    fi

    printf -- '── %s (%s) — спокій ──\n' "$lbl" "$w"
    if ! python3 render.py --layout "$LAYOUT" --state 1 --width "$w"; then
      echo "  (помилка рендеру — перевір синтаксис $LAYOUT; попередній кадр лишається дійсним)"
    fi
    echo
    printf -- '── %s (%s) — рух, агенти + coord ──\n' "$lbl" "$w"
    if ! python3 render.py --layout "$LAYOUT" --state 2 --width "$w"; then
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
last_mtime="$(mtime "$LAYOUT")"
last_width="$(term_width)"
while true; do
  sleep "$INTERVAL"
  cur_mtime="$(mtime "$LAYOUT")"
  cur_width="$(term_width)"
  if [ "$cur_mtime" != "$last_mtime" ] || [ "$cur_width" != "$last_width" ]; then
    last_mtime="$cur_mtime"
    last_width="$cur_width"
    draw
  fi
done
