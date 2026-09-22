#!/usr/bin/env bash
# Flags the tmux window an agent runs in when it finishes or needs input, and
# sends a macOS notification unless you are already looking at that window.
# Wired to Claude Code's Stop / Notification hooks. Must stay silent on stdout.

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

event=${1:-done}

target=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}' 2>/dev/null) || exit 0
[ -n "$target" ] || exit 0

# Already the active window of an attached session? You are looking at it, so
# there is nothing to flag and nothing to return to.
visible=$(tmux display-message -p -t "$TMUX_PANE" '#{window_active}#{session_attached}' 2>/dev/null)
[ "$visible" = "11" ] && exit 0

tmux set-option -w -t "$target" @wt_attention "$event" 2>/dev/null
tmux set-option -w -t "$target" @wt_attention_at "$(date +%s)" 2>/dev/null

label=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name} / #{window_name}' 2>/dev/null)
label=${label//\"/}
osascript -e "display notification \"${label}\" with title \"Agent ${event}\"" >/dev/null 2>&1

exit 0
