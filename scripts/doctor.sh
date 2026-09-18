#!/usr/bin/env bash
# wave-chat-title — doctor / preflight. Checks every dependency the plugin needs and, for anything
# missing, prints the EXACT install command for the detected OS. Safe to run any time.
#
#   bash doctor.sh           → check, print a report, exit 0 if all good / 1 if something's missing
#   bash doctor.sh --quiet   → only print problems (used by install.sh)
#
# Dependencies the plugin actually uses: bash, perl (+ core Text::Wrap), jq, plus coreutils
# (stat/cut/tr/wc/sed/head/tail/cksum) and git (optional — only for the ⎇ branch chip).
set -uo pipefail
quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1

# ---- colour (with no-colour fallback when not a tty / NO_COLOR set) -------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; X=$'\033[0m'
else R=""; G=""; Y=""; B=""; X=""; fi
ok(){   [ "$quiet" = 1 ] || printf '  %s✓%s %s\n' "$G" "$X" "$1"; }
bad(){  printf '  %s✗%s %s\n' "$R" "$X" "$1"; }
warn(){ [ "$quiet" = 1 ] || printf '  %s!%s %s\n' "$Y" "$X" "$1"; }
note(){ [ "$quiet" = 1 ] || printf '    %s\n' "$1"; }

# ---- detect OS / package hint --------------------------------------------------------------
os="unknown"; case "$(uname -s 2>/dev/null)" in
  Darwin) os="mac";;
  Linux)  os="linux";;
  MINGW*|MSYS*|CYGWIN*) os="windows";;   # Git Bash / MSYS2 / Cygwin on Windows
esac
# Linux package manager (for precise install hints)
pm=""; if [ "$os" = "linux" ]; then
  for c in apt-get dnf pacman zypper apk; do command -v "$c" >/dev/null 2>&1 && { pm="$c"; break; }; done
fi
# how to install <pkg> on this OS (echoes a command line)
inst(){ local pkg="$1"
  case "$os" in
    mac)     echo "brew install $pkg";;
    windows) echo "winget install $pkg   (або: scoop install $pkg  /  choco install $pkg)";;
    linux)   case "$pm" in
               apt-get) echo "sudo apt-get install -y $pkg";;
               dnf)     echo "sudo dnf install -y $pkg";;
               pacman)  echo "sudo pacman -S --noconfirm $pkg";;
               zypper)  echo "sudo zypper install -y $pkg";;
               apk)     echo "sudo apk add $pkg";;
               *)       echo "встанови пакет '$pkg' через свій менеджер пакетів";;
             esac;;
    *) echo "встанови '$pkg' для своєї системи";;
  esac; }

missing=0
[ "$quiet" = 1 ] || printf '%swave-chat-title — перевірка залежностей%s  (ОС: %s)\n' "$B" "$X" "$os"

# ---- bash ----------------------------------------------------------------------------------
if command -v bash >/dev/null 2>&1; then ok "bash ($(bash --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/'))"
else bad "bash — НЕМАЄ"; missing=1
  [ "$os" = "windows" ] && note "Встанови Git for Windows (дає Git Bash): https://git-scm.com/download/win"
fi

# ---- perl + Text::Wrap (core module, ships with perl) --------------------------------------
if command -v perl >/dev/null 2>&1; then
  if perl -MText::Wrap -e1 >/dev/null 2>&1; then ok "perl + Text::Wrap"
  else bad "perl є, але модуль Text::Wrap НЕ підвантажується"; missing=1
    note "Постав так: cpan Text::Wrap   (зазвичай він у ядрі perl, тож рідкісний випадок)"
  fi
else bad "perl — НЕМАЄ"; missing=1
  case "$os" in
    windows) note "Git for Windows містить perl. Встанови його: https://git-scm.com/download/win";;
    *) note "Встанови perl: $(inst perl)";;
  esac
fi

# ---- jq (NOT bundled with Git for Windows — the one thing Windows users must add) ----------
if command -v jq >/dev/null 2>&1; then ok "jq ($(jq --version 2>/dev/null))"
else bad "jq — НЕМАЄ (обов'язковий)"; missing=1
  note "Встанови: $(inst jq)"
  [ "$os" = "windows" ] && note "У Git for Windows jq НЕ входить — додай окремо (winget/scoop/choco) і перезапусти Git Bash."
fi

# ---- coreutils the scripts rely on ---------------------------------------------------------
cu_missing=""
for c in stat cut tr wc sed head tail cksum date grep; do command -v "$c" >/dev/null 2>&1 || cu_missing="$cu_missing $c"; done
if [ -z "$cu_missing" ]; then ok "coreutils (stat/cut/tr/wc/sed/head/tail/cksum/date/grep)"
else bad "бракує утиліт:$cu_missing"; missing=1
  note "На Windows вони йдуть із Git Bash; на Linux/Mac — у базовій системі."
fi

# ---- git (OPTIONAL — only the ⎇ branch chip needs it) -------------------------------------
if command -v git >/dev/null 2>&1; then ok "git (опційно — для чипа гілки ⎇)"
else warn "git нема — картка працює, але чип гілки ⎇ не показуватиметься"
  [ "$os" = "windows" ] && note "(git є в Git for Windows)"
fi

# ---- summary -------------------------------------------------------------------------------
echo
if [ "$missing" = 0 ]; then
  [ "$quiet" = 1 ] || printf '%s✓ Усе на місці — плагін запрацює.%s\n' "$G" "$X"
  exit 0
else
  printf '%s✗ Чогось бракує — встанови за командами вище й запусти doctor.sh ще раз.%s\n' "$R" "$X"
  [ "$os" = "windows" ] && printf '  %sWindows-порада:%s постав Git for Windows + jq, відкрий Git Bash, і запускай Claude Code звідти.\n' "$B" "$X"
  exit 1
fi
