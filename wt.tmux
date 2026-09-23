#!/usr/bin/env bash
# TPM entrypoint:  set -g @plugin 'Or-Priesender/tmux-wt'
#
# Sets the bindings and status-bar format straight from the plugin checkout, so
# no symlink into PATH is needed. The agent attention hook is NOT installed from
# here (it edits a file outside tmux) -- run ./install.sh --no-bin --no-tmux for
# that, once.
set -euo pipefail

PLUGIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

opt() {
  local v
  v=$(tmux show-option -gqv "$1" 2>/dev/null || true)
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

conf=$(bash "$PLUGIN_DIR/tmux/render.sh" \
  "$(opt @wt-bin "$PLUGIN_DIR/bin/wt")" \
  "$(opt @wt-key-new a)" \
  "$(opt @wt-key-jump A)" \
  "$(opt @wt-key-attention n)" \
  "$(opt @wt-key-next N)" \
  "$(opt @wt-key-rm Q)")

tmpf=$(mktemp -t wt.tmux) || exit 0
printf '%s\n' "$conf" > "$tmpf"
tmux source-file "$tmpf"
rm -f "$tmpf"
