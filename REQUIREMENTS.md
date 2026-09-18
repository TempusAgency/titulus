# wave-chat-title (Titulus) — requirements & install

The card is plain shell + perl + jq. It runs anywhere those three exist: **macOS, Linux, and
Windows**. Run the doctor any time to see what's missing on your machine:

```bash
bash scripts/doctor.sh
```

`install.sh` runs this check automatically and refuses to wire the card until everything is present.

## What it needs (all platforms)

| Tool | Why | Usually preinstalled? |
|---|---|---|
| **bash** | the card + hooks are bash scripts | mac ✓ · linux ✓ · Windows → comes with **Git for Windows** |
| **perl** + core module `Text::Wrap` | char-aware (Cyrillic) wrapping & layout | mac ✓ · linux ✓ · Windows → comes with **Git for Windows** |
| **jq** | reads Claude Code's JSON | **must install** (also on Windows) |
| coreutils (stat, cut, tr, wc, sed, head, tail, cksum, date, grep) | misc | mac/linux ✓ · Windows → Git for Windows ✓ |
| git *(optional)* | only the `⎇ branch` chip | — |
| A modern terminal (24-bit colour + OSC-8 links): Windows Terminal, iTerm2, Wave, etc. | colours & clickable folder | — |

## macOS

```bash
brew install jq        # perl, bash, coreutils already present
bash install.sh
```

## Linux

```bash
sudo apt-get install -y jq      # or: dnf / pacman / zypper / apk
bash install.sh
```

## Windows  (the important one)

Claude Code on Windows runs the status line and hooks **through Git Bash automatically** when it's
installed — so our bash/perl/jq scripts work as-is, no PowerShell rewrite. You just need two things:

1. **Install Git for Windows** (gives Git Bash + bash + perl + coreutils + git):
   <https://git-scm.com/download/win>
2. **Install jq** (Git for Windows does NOT include it):
   ```powershell
   winget install jqlang.jq      # or:  scoop install jq      or:  choco install jq
   ```
   Then **close and reopen Git Bash** so `jq` is on PATH.
3. From **Git Bash**, verify and install:
   ```bash
   bash scripts/doctor.sh        # should be all ✓
   bash install.sh
   ```

### Windows notes
- **Run Claude Code itself, and `install.sh`, from a context where Git Bash is available** — CC routes the `.sh` commands to Git Bash on its own.
- **Paths use forward slashes.** `install.sh` derives every path from `$HOME` (already forward-slash in Git Bash), so you never hand-write `C:\…`. Don't put backslash paths in `settings.json` — Git Bash eats them.
- **Line endings = LF.** A `.gitattributes` in this repo forces LF on all `.sh` files; if you copy scripts by hand, keep them LF (CRLF makes bash fail with `\r: command not found`).
- jq is the one piece people forget — if the card is blank, run `bash scripts/doctor.sh` first.
