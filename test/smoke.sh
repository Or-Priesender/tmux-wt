#!/usr/bin/env bash
# End-to-end smoke test for wt.
#
# Everything here runs against throwaway servers and a throwaway git repo. It
# never touches your real tmux server, your repos or your agent settings.
#
#   ./test/smoke.sh          run, then tear the sandbox down
#   ./test/smoke.sh --keep   leave the sandbox and the servers up to poke at
#
# Why it is built this way -- each of these cost a previous session real time:
#
#   * $TMUX overrides TMUX_TMPDIR, so an "isolated" server selected by
#     TMUX_TMPDIR is not isolated at all. Server isolation here is `tmux -L`
#     on a dedicated socket, and kill-server is NEVER run without -L.
#   * wt shells out to plain `tmux`, so the test puts a shim early on PATH that
#     execs the real tmux with `-L $INNER -f /dev/null`. The -f matters: without
#     it the test server sources your tmux.conf and any session hooks in it fire.
#   * A pane running your interactive shell sources your rc files, which on many
#     setups auto-attach tmux and swallow the keys sent to it. Panes here run
#     /bin/sh non-interactively.
#   * send-keys cannot trigger a tmux keybinding; it writes to the pane's pty
#     and bypasses key handling. Bindings are therefore checked by asserting the
#     command each one is bound to, not by pressing the key.
#   * switch-client needs an attached client. An outer server ($OUTER) holds a
#     pane attached to the inner one, which gives it exactly that.
set -uo pipefail

INNER=wt-smoke-inner
OUTER=wt-smoke-outer
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMUX_BIN=$(command -v tmux) || { echo "tmux is required"; exit 1; }
# -P: on macOS $TMPDIR is under /var, a symlink to /private/var, and git
# reports the resolved path. Comparing unresolved paths fails spuriously.
SBX=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wt-smoke.XXXXXX")" && pwd -P)
keep=0
[ "${1:-}" = "--keep" ] && keep=1

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '\033[32m  ok\033[0m %s\n' "$*"; }
no()   { fail=$((fail+1)); printf '\033[31mFAIL\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want [$3], got [$2])"; fi; }
has()  { if [ -e "$2" ]; then ok "$1"; else no "$1 (missing $2)"; fi; }
hasnt(){ if [ -e "$2" ]; then no "$1 ($2 still there)"; else ok "$1"; fi; }

itmux() { "$TMUX_BIN" -L "$INNER" -f /dev/null "$@"; }

cleanup() {
  if [ "$keep" = 1 ]; then
    printf '\n--keep: sandbox %s, servers: tmux -L %s / -L %s\n' "$SBX" "$INNER" "$OUTER"
    return
  fi
  # -L on every one of these. A bare kill-server would take out the real server.
  "$TMUX_BIN" -L "$OUTER" kill-server 2>/dev/null
  "$TMUX_BIN" -L "$INNER" kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$INNER" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OUTER"
  rm -rf "$SBX"
}
trap cleanup EXIT

# ---------------------------------------------------------------- sandbox ----
head_ "sandbox: $SBX"

export GIT_CONFIG_GLOBAL="$SBX/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --file "$GIT_CONFIG_GLOBAL" user.name "Smoke Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email smoke@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master

# A real `origin` so base_ref() resolves origin/HEAD the way it does in anger.
git init -q --bare "$SBX/origin.git"
git -C "$SBX/origin.git" symbolic-ref HEAD refs/heads/master
mkdir -p "$SBX/dev"
git clone -q "$SBX/origin.git" "$SBX/dev/demo" 2>/dev/null
D=$SBX/dev/demo
echo hi > "$D/README.md"
echo '.env*' > "$D/.gitignore"
printf '#!/bin/sh\nprintf %%s "$MAIN_REPO" > .setup-ran\n' > "$D/.worktree-setup"
chmod +x "$D/.worktree-setup"
git -C "$D" add -A
git -C "$D" commit -qm init
git -C "$D" push -q origin master
git -C "$D" remote set-head origin -a >/dev/null
echo 'SECRET=sandbox' > "$D/.env"
ok "repo with origin/HEAD -> $(git -C "$D" symbolic-ref refs/remotes/origin/HEAD)"

# A second checkout that deliberately never gets a tmux session, so the picker
# has to find it by scanning $WT_SCAN.
git clone -q "$SBX/origin.git" "$SBX/dev/lonely" 2>/dev/null
ok "second repo with no tmux session"

mkdir -p "$SBX/shim" "$SBX/out"
cat > "$SBX/shim/tmux" <<EOF
#!/bin/sh
exec $TMUX_BIN -L $INNER -f /dev/null "\$@"
EOF
chmod +x "$SBX/shim/tmux"

export PATH="$SBX/shim:$REPO/bin:$PATH"
export WT_ROOT="$SBX/worktrees" WT_SCAN="$SBX/dev" WT_PREFIX=tester
export WT_AGENT="sleep 600"   # stands in for the coding agent; must not exit
unset TMUX TMUX_PANE

# ------------------------------------------------------------------ servers --
head_ "servers"
itmux new-session -d -s demo -c "$D" -x 200 -y 50 /bin/sh
itmux set-option -g default-command /bin/sh   # no rc files in any pane wt opens
itmux set-option -g default-shell /bin/sh
itmux rename-window -t demo:0 host
"$TMUX_BIN" -L "$OUTER" -f /dev/null new-session -d -x 200 -y 50 \
  "$TMUX_BIN -L $INNER -f /dev/null attach -t demo"
sleep 1
is "inner server has an attached client" "$(itmux list-clients | wc -l | tr -d ' ')" "1"

# Runs a command in the host pane and waits for it to finish. send-keys is the
# only way in: the pane is a shell, not something we can exec into.
run() {
  rm -f "$SBX/out/rc"
  itmux send-keys -t '=demo:host' "$* > $SBX/out/log 2>&1; echo \$? > $SBX/out/rc" Enter
  local i=0
  while [ ! -f "$SBX/out/rc" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  cat "$SBX/out/rc" 2>/dev/null || echo timeout
}
log() { cat "$SBX/out/log" 2>/dev/null; }
# -q: a user option that was never set is not an error, it is just empty.
wopt() { itmux show-options -wqv -t "$1" "$2"; }

# ------------------------------------------------------------------ wt new ---
head_ "wt new"
is "exit status" "$(run wt new alpha)" "0"
has "worktree created"      "$SBX/worktrees/demo/alpha"
has "gitignored .env seeded" "$SBX/worktrees/demo/alpha/.env"
is  ".worktree-setup ran with MAIN_REPO" "$(cat "$SBX/worktrees/demo/alpha/.setup-ran" 2>/dev/null)" "$D"
is  "branch is prefixed with WT_PREFIX" \
    "$(git -C "$SBX/worktrees/demo/alpha" rev-parse --abbrev-ref HEAD 2>/dev/null)" "tester/alpha"
is  "tmux window opened" \
    "$(itmux list-windows -t '=demo' -F '#{window_name}' | grep -cx alpha)" "1"
is  "monitor-silence set on it" "$(wopt '=demo:alpha' monitor-silence)" "45"
is  "allow-rename off"          "$(wopt '=demo:alpha' allow-rename)" "off"
is  "switched the client to it" "$(itmux display-message -p -t demo '#{window_name}')" "alpha"
if itmux list-panes -t '=demo:alpha' -F '#{pane_current_command}' | grep -q sleep; then
  ok "\$WT_AGENT was launched in the window"
else
  no "\$WT_AGENT was launched in the window"
fi
is "refuses to clobber an existing workspace" "$(run wt new alpha)" "1"

# ------------------------------------------------------------- attention ----
head_ "attention hook"
pane=$(itmux list-panes -t '=demo:alpha' -F '#{pane_id}')
fire() { env -u TMUX TMUX_PANE="$pane" "$REPO/hooks/wt-attention.sh" "$1"; }

# Looking straight at the window: nothing to flag, nothing to return to.
fire done
is "no flag while the window is visible" "$(wopt '=demo:alpha' @wt_attention)" ""

itmux select-window -t '=demo:host'
fire done
is "flags the window once you look away" "$(wopt '=demo:alpha' @wt_attention)" "done"
if [ -n "$(wopt '=demo:alpha' @wt_attention_at)" ]; then ok "records a timestamp"; else no "records a timestamp"; fi
fire waiting
is "distinguishes waiting from done" "$(wopt '=demo:alpha' @wt_attention)" "waiting"

is "status format renders the ! flag" \
   "$(itmux list-windows -t '=demo' -F '#{window_name}#{?@wt_attention,!,}' | grep -cx 'alpha!')" "1"

head_ "wt attention"
is "--next exit status" "$(run wt attention --next)" "0"
is "jumped to the flagged window" "$(itmux display-message -p -t demo '#{window_name}')" "alpha"
is "cleared the flag"    "$(wopt '=demo:alpha' @wt_attention)" ""
is "cleared the stamp"   "$(wopt '=demo:alpha' @wt_attention_at)" ""
is "--auto with nothing waiting is a no-op, not an error" "$(run wt attention --auto)" "0"

# ------------------------------------------------------------------- wt ls ---
head_ "wt ls"
is "exit status" "$(run wt ls)" "0"
if log | grep -q '^alpha .*tester/alpha .*live'; then ok "lists the workspace as live"; else no "lists the workspace as live: $(log)"; fi
is "--all exit status" "$(run wt ls --all)" "0"
if log | grep -q '^demo  *alpha'; then ok "--all groups by repo"; else no "--all groups by repo: $(log)"; fi

# --------------------------------------------------------------- wt rename ---
head_ "wt rename"
is "exit status" "$(run wt rename alpha PROJ-1234)" "0"
has  "moved on disk"  "$SBX/worktrees/demo/PROJ-1234"
hasnt "old path gone" "$SBX/worktrees/demo/alpha"
is "a Jira-style name is used verbatim, not prefixed" \
   "$(git -C "$SBX/worktrees/demo/PROJ-1234" rev-parse --abbrev-ref HEAD 2>/dev/null)" "PROJ-1234"
is "tmux window renamed" \
   "$(itmux list-windows -t '=demo' -F '#{window_name}' | grep -cx PROJ-1234)" "1"
# Gotcha 8: a running process's cwd follows the move, so the agent survives it.
if itmux list-panes -t '=demo:PROJ-1234' -F '#{pane_current_command}' | grep -q sleep; then
  ok "the agent in the window survived the move"
else
  no "the agent in the window survived the move"
fi

# ------------------------------------------------------------------- wt rm ---
head_ "wt rm"
is "declining the prompt aborts" "$(run 'echo n | wt rm PROJ-1234')" "1"
has "workspace still there" "$SBX/worktrees/demo/PROJ-1234"
is "confirming removes it" "$(run 'echo y | wt rm PROJ-1234')" "0"
hasnt "worktree gone" "$SBX/worktrees/demo/PROJ-1234"
is "window killed" "$(itmux list-windows -t '=demo' -F '#{window_name}' | grep -cx PROJ-1234)" "0"
is "merged branch deleted" \
   "$(git -C "$D" branch --list PROJ-1234 | wc -l | tr -d ' ')" "0"

head_ "wt rm keeps unmerged work"
run wt new beta >/dev/null
echo change > "$SBX/worktrees/demo/beta/file.txt"
git -C "$SBX/worktrees/demo/beta" add -A
git -C "$SBX/worktrees/demo/beta" commit -qm work
is "removed" "$(run 'echo y | wt rm beta')" "0"
is "unmerged branch kept" \
   "$(git -C "$D" branch --list tester/beta | wc -l | tr -d ' ')" "1"

head_ "wt new with no name (the prefix + a path)"
# The picker needs a tty, so it runs in the pane like everything else. fzf's
# --filter makes it non-interactive: it prints the matching line and exits,
# which is enough to drive pick_repo without a human.
is "no tmux session for the second repo yet" \
   "$(itmux list-sessions -F '#{session_name}' | grep -cx lonely)" "0"
rm -f "$SBX/out/rc"
itmux send-keys -t '=demo:host' \
  "FZF_DEFAULT_OPTS='--filter=lonely' wt new > $SBX/out/log 2>&1; echo \$? > $SBX/out/rc" Enter
sleep 2
itmux send-keys -t '=demo:host' "scanned" Enter   # answers the name prompt
i=0; while [ ! -f "$SBX/out/rc" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
is "exit status" "$(cat "$SBX/out/rc" 2>/dev/null || echo timeout)" "0"
has "reached a repo that had no session" "$SBX/worktrees/lonely/scanned"
is "created its session" "$(itmux list-sessions -F '#{session_name}' | grep -cx lonely)" "1"
is "and its window"      "$(itmux list-windows -t '=lonely' -F '#{window_name}' | grep -cx scanned)" "1"

# ------------------------------------------------------------------ config ---
head_ "tmux config block"
conf=$("$REPO/tmux/render.sh" /opt/example/wt)
is "no placeholders left" "$(printf '%s' "$conf" | grep -c '@WT_[A-Z_]*@')" "0"
tf=$SBX/out/wt.conf; printf '%s\n' "$conf" > "$tf"
if itmux source-file "$tf" 2>"$SBX/out/src.err"; then ok "tmux accepts the block"
else no "tmux rejects the block: $(cat "$SBX/out/src.err")"; fi
# send-keys cannot fire a binding, so assert what the key is bound to instead.
binds=$(itmux list-keys -T prefix)
for k in 'a .*wt new' 'A .*wt jump' 'n .*attention --auto' 'N .*attention --next'; do
  key=${k%% *}
  if printf '%s' "$binds" | grep -qE "bind-key +-T prefix +$k"; then
    ok "prefix + $key is bound"
  else
    no "prefix + $key is bound"
  fi
done

# ------------------------------------------------------------------- hooks ---
head_ "agent hook installer"
cat > "$SBX/out/settings.json" <<'JSON'
{ "env": {"KEEP": "me"},
  "hooks": { "Stop": [{"hooks":[{"type":"command","command":"/foreign/tool.sh"}]}] } }
JSON
H="$REPO/hooks/install-agent-hook.sh"
bash "$H" --hook /opt/example/wt-attention.sh --settings "$SBX/out/settings.json" >/dev/null
q() { python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))' "$SBX/out/settings.json"; }
if q | grep -q '/foreign/tool.sh'; then ok "left the foreign hook alone"; else no "left the foreign hook alone"; fi
if q | grep -q 'wt-attention.sh done'; then ok "registered Stop"; else no "registered Stop"; fi
if q | grep -q 'wt-attention.sh waiting'; then ok "registered Notification"; else no "registered Notification"; fi
bash "$H" --hook /opt/example/wt-attention.sh --settings "$SBX/out/settings.json" >"$SBX/out/second"
if grep -q 'already up to date' "$SBX/out/second"; then ok "re-running changes nothing"; else no "re-running changes nothing"; fi

# A foreign tool uninstalls itself; ours must survive that.
python3 - "$SBX/out/settings.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["hooks"]["Stop"]=[g for g in d["hooks"]["Stop"]
                    if not any("/foreign/" in h.get("command","") for h in g.get("hooks",[]))]
json.dump(d,open(p,"w"),indent=2)
PY
if q | grep -q 'wt-attention.sh done'; then ok "survives a foreign uninstall"; else no "survives a foreign uninstall"; fi

bash "$H" --uninstall --settings "$SBX/out/settings.json" >/dev/null
if q | grep -q 'wt-attention'; then no "uninstall removes our entries"; else ok "uninstall removes our entries"; fi
if q | grep -q '"KEEP": "me"'; then ok "uninstall leaves the rest of the file"; else no "uninstall leaves the rest of the file"; fi

# ------------------------------------------------------------------ result ---
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" = 0 ]
