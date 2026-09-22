#!/usr/bin/env bash
# tmux-wt installer. Re-runnable: every step is idempotent.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
BEGIN='# >>> tmux-wt >>>'
END='# <<< tmux-wt <<<'

do_tmux=1 do_hook=1 do_bin=1 tmux_conf=

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX=${2:?--prefix needs a path}; shift ;;
    --tmux-conf) tmux_conf=${2:?--tmux-conf needs a path}; shift ;;
    --claude-dir) CLAUDE_DIR=${2:?--claude-dir needs a path}; shift ;;
    --no-tmux) do_tmux=0 ;;
    --no-hook) do_hook=0 ;;
    --no-bin) do_bin=0 ;;
    -h|--help)
      cat <<USAGE
usage: ./install.sh [options]

  --prefix DIR       install the wt symlink into DIR/bin   (default: ~/.local)
  --tmux-conf FILE   tmux config to edit                   (default: autodetected)
  --claude-dir DIR   agent config dir for the hook         (default: ~/.claude)
  --no-bin           skip the wt symlink
  --no-tmux          skip the tmux.conf block
  --no-hook          skip the agent attention hook
USAGE
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "preflight"
command -v tmux >/dev/null || die "tmux is not installed"
ok "tmux $(tmux -V | awk '{print $2}')"

command -v git >/dev/null || die "git is not installed"
gitver=$(git --version | sed -E 's/[^0-9]*([0-9]+\.[0-9]+).*/\1/')
# 2.17 is where `git worktree move` landed, which `wt rename` needs.
if [ "$(printf '%s\n2.17\n' "$gitver" | sort -V | head -1)" != "2.17" ]; then
  die "git $gitver is too old; wt rename needs >= 2.17 for 'git worktree move'"
fi
ok "git $gitver"

if command -v fzf >/dev/null; then
  ok "fzf $(fzf --version | awk '{print $1}')"
else
  warn "fzf not found: 'wt jump', 'wt new' with no name, and the attention picker will not work"
fi

if [ "$do_hook" = 1 ] && ! command -v python3 >/dev/null; then
  warn "python3 not found: skipping the attention hook"
  do_hook=0
fi

if [ "$do_bin" = 1 ]; then
  step "wt -> $PREFIX/bin/wt"
  mkdir -p "$PREFIX/bin"
  ln -sfn "$REPO/bin/wt" "$PREFIX/bin/wt"
  ok "symlinked"
  case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) warn "$PREFIX/bin is not on your PATH; add it to your shell rc" ;;
  esac
fi

if [ "$do_tmux" = 1 ]; then
  if [ -z "$tmux_conf" ]; then
    for c in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" "$HOME/.tmux.conf"; do
      if [ -f "$c" ]; then tmux_conf=$c; break; fi
    done
    : "${tmux_conf:=${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf}"
  fi
  step "tmux block -> $tmux_conf"
  mkdir -p "$(dirname "$tmux_conf")"
  [ -f "$tmux_conf" ] || : > "$tmux_conf"

  block=$(bash "$REPO/tmux/render.sh" "${PREFIX}/bin/wt")
  BEGIN="$BEGIN" END="$END" BLOCK="$block" CONF="$tmux_conf" python3 - <<'PY'
import os, pathlib, re
conf = pathlib.Path(os.environ["CONF"])
begin, end = os.environ["BEGIN"], os.environ["END"]
block = f"{begin}\n{os.environ['BLOCK']}\n{end}\n"
text = conf.read_text()
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.S)
if pattern.search(text):
    new, action = pattern.sub(block, text, count=1), "replaced"
else:
    sep = "" if text == "" or text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    new, action = text + sep + block, "appended"
if new != text:
    conf.write_text(new)
print(action)
PY
  ok "block written between the markers"
  # Our block sets window-status-format. Anything setting it after the end
  # marker (a theme, a plugin) overrides us and the '!' flag disappears.
  if awk -v e="$END" 'f && /window-status-(current-)?format/ {hit=1} $0==e {f=1} END {exit !hit}' "$tmux_conf"; then
    warn "something after the tmux-wt block also sets window-status-format; move the block to the end of $tmux_conf or the '!' attention flag will not show"
  fi
  ok "reload with: tmux source-file $tmux_conf"
fi

if [ "$do_hook" = 1 ]; then
  step "attention hook -> $CLAUDE_DIR"
  mkdir -p "$CLAUDE_DIR/hooks"
  ln -sfn "$REPO/hooks/wt-attention.sh" "$CLAUDE_DIR/hooks/wt-attention.sh"
  ok "symlinked $CLAUDE_DIR/hooks/wt-attention.sh"
  # Register it as $HOME/... so the settings file stays portable across machines.
  hookpath="$CLAUDE_DIR/hooks/wt-attention.sh"
  case "$hookpath" in "$HOME"/*) hookpath="\$HOME${hookpath#"$HOME"}" ;; esac
  bash "$REPO/hooks/install-agent-hook.sh" \
    --hook "$hookpath" --settings "$CLAUDE_DIR/settings.json"
fi

printf '\n\033[1mdone.\033[0m Restart your agent so it picks up the hook, then try prefix + a.\n'
