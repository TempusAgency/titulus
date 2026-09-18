#!/usr/bin/env bash
# demo.sh — print the variant B "Сегменти" reference card in all 7 states.
#
# Read-only: this script only prints. It never touches statusline.sh or any
# other file in the plugin repo. Porting this design into the production
# status line is a separate, later task.
#
# Usage:
#   ./demo.sh                # print all 7 canonical states (color if TTY)
#   ./demo.sh --verify        # diff render.py's output against REFERENCE.md
#   ./demo.sh --audit         # width gate: 7 states x 2 cut levels x 6 widths
#   ./demo.sh --state 6       # print a single state
#   NO_COLOR=1 ./demo.sh      # force plain text (also: --no-color)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FONT="$HOME/Library/Fonts/TempusGlyphs-Regular.ttf"
if [ ! -f "$FONT" ]; then
    echo "warning: $FONT not found — rounded corners (U+E87E/U+E881) will show as tofu/blank in your terminal." >&2
fi

exec python3 render.py "$@"
