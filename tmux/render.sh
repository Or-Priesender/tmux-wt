#!/usr/bin/env bash
# Renders tmux/wt.conf.in to stdout with the real wt path and key bindings.
# usage: render.sh <wt-bin> [key_new] [key_jump] [key_attention] [key_next]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin=${1:?usage: render.sh <wt-bin> [keys...]}

sed -e "s|@WT_BIN@|$bin|g" \
    -e "s|@WT_KEY_NEW@|${2:-a}|g" \
    -e "s|@WT_KEY_JUMP@|${3:-A}|g" \
    -e "s|@WT_KEY_ATTENTION@|${4:-n}|g" \
    -e "s|@WT_KEY_NEXT@|${5:-N}|g" \
    "$here/wt.conf.in"
