#!/usr/bin/env bash
# design/rollback.sh — restore the live/production layout (layout.conf) from the most recent
# backup made by apply.sh (layout.conf.bak-<timestamp>). Never touches layout.sandbox.conf.
#
# Usage:
#   ./rollback.sh              # find latest backup, ask to confirm, restore it
#   ./rollback.sh --yes        # same, but skip the confirmation prompt (for scripts)
#   ./rollback.sh --list       # just list available backups, newest first; restore nothing
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

LIVE="layout.conf"
ASSUME_YES=0
LIST_ONLY=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  --list) LIST_ONLY=1 ;;
esac

# Portable (bash 3.2-compatible — no mapfile/readarray) collection of backups, newest first.
BACKUPS=()
while IFS= read -r f; do
  [ -n "$f" ] && BACKUPS+=("$f")
done < <(ls -1t "${LIVE}".bak-* 2>/dev/null)

if [ "${#BACKUPS[@]}" -eq 0 ]; then
  echo "rollback.sh: жодного бекапу ${LIVE}.bak-* не знайдено в design/ — відкочувати нема з чого." >&2
  exit 1
fi

if [ "$LIST_ONLY" = 1 ]; then
  echo "Доступні бекапи $LIVE (найновіший перший):"
  printf '  %s\n' "${BACKUPS[@]}"
  exit 0
fi

LATEST="${BACKUPS[0]}"
echo "Знайдено останній бекап: $LATEST"

if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
  read -r -p "Відкотити $LIVE до цього бекапу? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "rollback.sh: скасовано, $LIVE не чіпав."; exit 0 ;;
  esac
fi

STAMP="$(date +%Y-%m-%d_%H%M%S)"
SAFETY="${LIVE}.bak-${STAMP}-pre-rollback"
cp "$LIVE" "$SAFETY"
echo "Поточний $LIVE збережено як $SAFETY (про всяк випадок, якщо відкат теж треба буде скасувати)."

cp "$LATEST" "$LIVE"
echo "Відкочено: $LATEST -> $LIVE"
echo
echo "Перевір: python3 render.py --verify && python3 render.py --audit"
