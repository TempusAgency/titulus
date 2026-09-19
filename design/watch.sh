#!/usr/bin/env bash
# design/watch.sh — live preview for the Titulus card layout.
#
# Draws the card at the CURRENT window width, edge to edge (no fixed 80/38-column panels,
# no side margins). Redraws the moment `layout.conf` changes on disk, the moment the window is
# resized, or on demand (key toggle below) — so you can edit the config in your editor, or just
# drag the window edge, and see the effect immediately without touching statusline.sh or running
# an agent.
#
# Two frames are shown, one under the other, both at the same width: "спокій" (state 1, idle)
# and "рух" (state 2, agents + coord running) — so the difference between the two is visible at
# a glance, at whatever width you're actually looking at. (Two static frames, not a live-cycling
# animation: `render.py --state N` renders one fixed scene per state; there is no "spinner as
# time passes" mode to switch between, and holding both still on screen together is more useful
# for eyeballing a layout.conf edit than flipping between them.)
#
# WIDTH: production Claude Code shaves a few columns off $COLUMNS for its own UI chrome before
# drawing the card (see statusline.sh, $user_dir/.width_margin) — a plain terminal (this preview)
# has no such chrome. So:
#   - default: full window width, no margin subtracted — shows the maximum the layout can use.
#   - press 'c': toggles a second mode that subtracts the SAME margin production uses (read from
#     the same file: ~/.claude/wave-chat-title/.width_margin, fallback 3, matching statusline.sh),
#     so you can see exactly what the card looks like inside Claude Code at this window size.
#   Both modes are explained in a line printed above the frames every redraw.
#
# No external dependencies (no fswatch/entr — may not be installed): change detection is a plain
# mtime poll, using only `stat` + a `[ ]` comparison, once per poll tick (default every 0.3s, see
# WCT_WATCH_INTERVAL below). Window width is read fresh every tick with `tput cols` (part of the
# base OS terminfo toolset, same tier as `stat`).
#
# FLICKER: each redraw does NOT clear the screen first. It homes the cursor (`\033[H`), draws the
# new frame directly on top of the old one, then erases only what's left over below the new
# content (`\033[0J`) — so unchanged rows are simply overwritten in place instead of the whole
# screen going blank-then-redrawn. That's what a full `clear` does and is the actual source of
# visible flicker; this avoids it.
#
# The poll tick doubles as the keyboard read: `read -t INTERVAL -n1` either returns a keypress
# immediately or times out after INTERVAL seconds, so toggling the width mode reacts instantly
# and a plain resize/edit is still picked up within one tick. Falls back to a plain `sleep` loop
# (no key handling) when stdin isn't a terminal.
#
# Usage:
#   ./watch.sh                    # watch design/layout.conf (default)
#   ./watch.sh path/to/other.conf # watch a different layout file (e.g. a scratch copy)
#   WCT_WATCH_INTERVAL=0.5 ./watch.sh
#
# Keys:
#   c        toggle width mode: full window width  <->  "as in Claude Code" (minus margin)
#   q        quit (same as Ctrl+C)
#
# Ctrl+C exits cleanly: restores the cursor, no child processes left behind (the only children
# are short-lived `python3 render.py` calls per redraw — none of them outlive this script; the
# `read -t`/`sleep` in the poll loop is the only thing running between redraws, and the INT/TERM
# trap kills the script before another tick/redraw can start).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

LAYOUT="${1:-layout.conf}"
INTERVAL="${WCT_WATCH_INTERVAL:-0.3}"
MIN_CARD_WIDTH=10   # floor for the "as in Claude Code" mode so width-minus-margin never goes <=0

if [ ! -f "$LAYOUT" ]; then
  echo "watch.sh: layout file not found: $LAYOUT" >&2
  exit 1
fi

FONT="$HOME/Library/Fonts/TempusGlyphs-Regular.ttf"
if [ ! -f "$FONT" ]; then
  echo "warning: $FONT not found — rounded corners (U+E87E/U+E881) show as tofu/blank." >&2
fi

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Actual terminal width, read fresh on demand. `tput cols` queries the terminal directly and
# reacts to a live resize; $COLUMNS is the fallback for the rare case tput is missing/fails
# (e.g. no controlling terminal) — same fallback chain statusline.sh itself uses for the
# production card.
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

# Same margin production reads — see statusline.sh, $user_dir/.width_margin — so mode 'c' shows
# the exact width Claude Code would give the card at this window size.
margin_file="$HOME/.claude/wave-chat-title/.width_margin"
read_margin() {
  local m=""
  if [ -s "$margin_file" ]; then m="$(<"$margin_file")"; fi
  case "$m" in ''|*[!0-9]*) m=3;; esac
  printf '%s' "$m"
}
WMARGIN="$(read_margin)"

cleanup() {
  printf '\033[?25h'   # restore cursor
  printf '\nwatch.sh: зупинено.\n'
}
trap cleanup EXIT
trap 'exit 0' INT TERM

MODE=0   # 0 = full window width (default), 1 = as in Claude Code (minus margin)

draw() {
  local tw w mode_label note
  tw="$(term_width)"
  if [ "$MODE" = 1 ]; then
    w=$((tw - WMARGIN))
    [ "$w" -lt "$MIN_CARD_WIDTH" ] && w="$MIN_CARD_WIDTH"
    mode_label="як у Claude Code (вікно мінус ${WMARGIN} кол. запасу під інтерфейс)"
    note="У Claude Code картка вужча за термінал на ${WMARGIN} кол. — тут це відтворено. Натисни c — назад на повну ширину."
  else
    w="$tw"
    mode_label="повна ширина вікна (запас не віднімається)"
    note="Показано на повну ширину вікна — тут запасу немає, це звичайний термінал. У Claude Code картка буде вужча на ${WMARGIN} кол.; натисни c, щоб побачити саме так."
  fi

  printf '\033[H'   # cursor home — no full clear, avoids the blank-then-redraw flicker
  printf '\033[1mTitulus — живий перегляд картки\033[0m   файл: %s   [c] режим ширини   [q]/Ctrl+C вихід\n' "$LAYOUT"
  printf 'вікно: %s кол.   режим: %s   ширина картки: %s кол.   оновлено: %s\n' \
    "$tw" "$mode_label" "$w" "$(date '+%H:%M:%S')"
  printf '%s\n\n' "$note"

  echo "── спокій ──"
  if ! python3 render.py --layout "$LAYOUT" --state 1 --width "$w"; then
    echo "  (помилка рендеру — перевір синтаксис $LAYOUT; попередній кадр лишається дійсним)"
  fi
  echo
  echo "── рух: агенти + coord ──"
  if ! python3 render.py --layout "$LAYOUT" --state 2 --width "$w"; then
    echo "  (помилка рендеру — перевір синтаксис $LAYOUT; попередній кадр лишається дійсним)"
  fi

  echo
  echo "Правила ширини/токенів — дивись коментар на початку $LAYOUT."
  echo "Після правки: python3 render.py --verify && python3 render.py --audit"
  echo "Прев'ю в середовищах (Claude Code реальний / Codex макет): ./preview-env.sh"
  printf '\033[0J'   # erase anything left over below from a taller previous frame
}

printf '\033[?25l'   # hide cursor while the preview is live
draw
last_mtime="$(mtime "$LAYOUT")"
last_width="$(term_width)"

INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

while true; do
  if [ "$INTERACTIVE" = 1 ]; then
    if read -t "$INTERVAL" -n 1 -s -r key; then
      case "$key" in
        c|C) MODE=$((1 - MODE)); draw; continue ;;
        q|Q) exit 0 ;;
      esac
    fi
  else
    sleep "$INTERVAL"
  fi
  cur_mtime="$(mtime "$LAYOUT")"
  cur_width="$(term_width)"
  if [ "$cur_mtime" != "$last_mtime" ] || [ "$cur_width" != "$last_width" ]; then
    last_mtime="$cur_mtime"
    last_width="$cur_width"
    draw
  fi
done
