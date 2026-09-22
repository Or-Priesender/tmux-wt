#!/usr/bin/env bash
# Reverses install.sh. Leaves the repo, your worktrees and your branches alone.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
BEGIN='# >>> tmux-wt >>>'
END='# <<< tmux-wt <<<'
tmux_conf=

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX=${2:?--prefix needs a path}; shift ;;
    --tmux-conf) tmux_conf=${2:?--tmux-conf needs a path}; shift ;;
    --claude-dir) CLAUDE_DIR=${2:?--claude-dir needs a path}; shift ;;
    -h|--help) echo "usage: ./uninstall.sh [--prefix DIR] [--tmux-conf FILE] [--claude-dir DIR]"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "wt symlink"
if [ -L "$PREFIX/bin/wt" ]; then
  rm -f "$PREFIX/bin/wt"; ok "removed $PREFIX/bin/wt"
else
  ok "$PREFIX/bin/wt is not our symlink; left alone"
fi

if [ -z "$tmux_conf" ]; then
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" "$HOME/.tmux.conf"; do
    if [ -f "$c" ]; then tmux_conf=$c; break; fi
  done
fi
step "tmux block"
if [ -n "$tmux_conf" ] && [ -f "$tmux_conf" ]; then
  BEGIN="$BEGIN" END="$END" CONF="$tmux_conf" python3 - <<'PY'
import os, pathlib, re
conf = pathlib.Path(os.environ["CONF"])
text = conf.read_text()
pattern = re.compile(r"\n*" + re.escape(os.environ["BEGIN"]) + r".*?"
                     + re.escape(os.environ["END"]) + r"\n?", re.S)
new = pattern.sub("\n", text, count=1)
if new != text:
    conf.write_text(new)
    print(f"removed the block from {conf}")
else:
    print(f"no tmux-wt block in {conf}")
PY
  ok "reload with: tmux source-file $tmux_conf"
else
  ok "no tmux config found; nothing to do"
fi

step "attention hook"
if command -v python3 >/dev/null; then
  bash "$REPO/hooks/install-agent-hook.sh" --uninstall --settings "$CLAUDE_DIR/settings.json"
fi
if [ -L "$CLAUDE_DIR/hooks/wt-attention.sh" ]; then
  rm -f "$CLAUDE_DIR/hooks/wt-attention.sh"; ok "removed the hook symlink"
fi

printf '\n\033[1mdone.\033[0m Existing worktrees under $WT_ROOT were not touched.\n'
