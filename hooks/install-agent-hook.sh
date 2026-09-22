#!/usr/bin/env bash
# Registers (or removes) the wt attention hook in an agent's settings.json.
#
# The file is shared with every other tool that installs hooks, so this only
# ever adds or removes its own group and leaves foreign entries untouched.
#
# usage: install-agent-hook.sh [--uninstall] [--hook PATH] [--settings PATH]
set -euo pipefail

hook="$HOME/.claude/hooks/wt-attention.sh"
settings="$HOME/.claude/settings.json"
action=install

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) action=uninstall ;;
    --hook) hook=${2:?--hook needs a path}; shift ;;
    --settings) settings=${2:?--settings needs a path}; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null || { echo "install-agent-hook.sh needs python3" >&2; exit 1; }

ACTION=$action HOOK=$hook SETTINGS=$settings python3 - <<'PY'
import json, os, pathlib, shutil

action = os.environ["ACTION"]
hook = os.environ["HOOK"]
path = pathlib.Path(os.environ["SETTINGS"])
MARKER = "wt-attention.sh"
EVENTS = (("Stop", "done"), ("Notification", "waiting"))

if not path.exists():
    if action == "uninstall":
        print(f"{path}: not present; nothing to do")
        raise SystemExit(0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{}\n")

try:
    data = json.loads(path.read_text() or "{}")
except json.JSONDecodeError as e:
    raise SystemExit(f"{path} is not valid JSON ({e}); refusing to touch it")

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    if action == "uninstall":
        print(f"{path}: no hooks block; nothing to do")
        raise SystemExit(0)
    hooks = data.setdefault("hooks", {})

changed = []

def is_ours(entry):
    return MARKER in entry.get("command", "")

if action == "install":
    for event, arg in EVENTS:
        want = f"{hook} {arg}"
        groups = hooks.setdefault(event, [])
        found = False
        for group in groups:
            for entry in group.get("hooks", []):
                if is_ours(entry):
                    found = True
                    if entry.get("command") != want:
                        entry["command"] = want
                        changed.append(f"{event}: updated")
        if not found:
            groups.append({"hooks": [{"type": "command", "command": want, "timeout": 5}]})
            changed.append(f"{event}: added")
else:
    for event, _ in EVENTS:
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            entries = group.get("hooks", [])
            remaining = [e for e in entries if not is_ours(e)]
            if len(remaining) != len(entries):
                changed.append(f"{event}: removed")
            # A group emptied of our entries goes; one that held other tools' stays.
            if remaining:
                group["hooks"] = remaining
                kept.append(group)
            elif not entries:
                kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if not hooks:
        data.pop("hooks", None)

if changed:
    shutil.copy(path, str(path) + ".bak")
    path.write_text(json.dumps(data, indent=2) + "\n")
    print("\n".join(dict.fromkeys(changed)) + f"\n  {path} (backup: {path}.bak)")
else:
    print(f"{path}: already up to date")
PY
