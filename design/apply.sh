#!/usr/bin/env bash
# design/apply.sh — promote the sandbox layout (layout.sandbox.conf) to the live/production
# layout (layout.conf), which statusline.sh actually reads for the real card.
#
# SAFETY GATE: refuses to touch layout.conf unless BOTH of these pass against the sandbox file:
#   python3 render.py --layout layout.sandbox.conf --verify
#   python3 render.py --layout layout.sandbox.conf --audit
# If either fails, layout.conf is NOT touched — the failing output is printed as-is and the
# script exits non-zero, so you can see exactly what to fix in the sandbox before trying again.
#
# BACKUP: before overwriting layout.conf, the CURRENT live config is copied to a timestamped
# backup — layout.conf.bak-<YYYY-MM-DD_HHMMSS> — matching this repo's existing "*.bak-*"
# convention (already gitignored; kept on disk locally, not published). Use ./rollback.sh to
# restore the most recent one.
#
# Usage:
#   ./apply.sh              # run the gate, then (if it passes) promote sandbox -> live
#   ./apply.sh --dry-run    # run the gate only; report the verdict; touch nothing
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SANDBOX="layout.sandbox.conf"
LIVE="layout.conf"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ ! -f "$SANDBOX" ]; then
  echo "apply.sh: $SANDBOX не знайдено — нема що застосовувати." >&2
  exit 1
fi
if [ ! -f "$LIVE" ]; then
  echo "apply.sh: $LIVE (бойовий конфіг) не знайдено — щось не так із репо, зупиняюсь." >&2
  exit 1
fi

echo "== Перевірка пісочниці ($SANDBOX) перед застосуванням =="
echo
echo "-- verify --"
if ! python3 render.py --layout "$SANDBOX" --verify; then
  echo
  echo "apply.sh: ВІДМОВА — --verify НЕ пройшов для $SANDBOX (див. FAIL вище). $LIVE НЕ змінено." >&2
  exit 1
fi
echo
echo "-- audit --"
if ! python3 render.py --layout "$SANDBOX" --audit; then
  echo
  echo "apply.sh: ВІДМОВА — --audit НЕ пройшов для $SANDBOX (є порушення ширини вище). $LIVE НЕ змінено." >&2
  exit 1
fi

echo
echo "Обидві перевірки пройшли (verify PASS, audit 0 порушень)."

if [ "$DRY_RUN" = 1 ]; then
  echo "apply.sh: --dry-run — $LIVE НЕ змінено (тільки перевірка)."
  exit 0
fi

if cmp -s "$SANDBOX" "$LIVE"; then
  echo "apply.sh: $SANDBOX і $LIVE вже однакові — застосовувати нічого, $LIVE не чіпав."
  exit 0
fi

STAMP="$(date +%Y-%m-%d_%H%M%S)"
BACKUP="${LIVE}.bak-${STAMP}"
cp "$LIVE" "$BACKUP"
echo "Бекап попереднього $LIVE -> $BACKUP"

cp "$SANDBOX" "$LIVE"
echo "Застосовано: $SANDBOX -> $LIVE"
echo
echo "Живий statusline.sh читає $LIVE напряму (design/layout.conf у repo-режимі) — зміна вже діє"
echo "для наступних рендерів картки в Claude Code."
echo "Якщо щось не так — відкотити: ./rollback.sh"
