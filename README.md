# tmux-wt

One git worktree per task, each in its own tmux window, so several coding agents
run in parallel without colliding. Agents flag their own window when they finish
or need input, and you jump to whichever one is waiting with two keys.

```
prefix + a      new workspace   (fzf-pick a repo, name it, agent starts in a new window)
prefix + A      jump to one
prefix + n      go to an agent that is waiting on you
```

The installed command is `wt`. The repo is called `tmux-wt` for discoverability.

## Why

Running three coding agents in one checkout does not work: they fight over the
working tree. Running them in three worktrees works, but then you are managing
three directories, three branches and three terminals by hand, and you have no
idea which agent is blocked on a permission prompt while you are looking at
another window.

`wt` makes the worktree, the branch and the tmux window one unit, and it makes
"which agent needs me" a keystroke.

### Compared to Orca

This is the workspace model of the [Orca](https://orcastudio.io) desktop app,
rebuilt for people who live in tmux. The behaviour was matched deliberately:
worktrees under a single workspace directory, branches prefixed with your git
username, `.env` files seeded into each new worktree, the agent auto-started in
the new window, and a fish codename when you have not named the task yet.

What you get over Orca is that it is tmux, so it is over SSH, it survives a
disconnect, and it composes with the rest of your tmux config. What you give up
is Orca's GUI.

### Compared to tmux-notify

[`rickstaa/tmux-notify`](https://github.com/rickstaa/tmux-notify) solves a
neighbouring problem and is worth knowing about. It polls pane content every 10
seconds and calls a process done when the visible text ends in `$`, `#` or `%`.

That is a good heuristic for `make`, but it does not fit agents. It is opt-in per
pane, it misfires on themed prompts (anything not ending in those three
characters), and it fundamentally cannot tell "finished" from "waiting for
input", because an agent sitting at a permission prompt never returns to a shell
prompt at all.

`tmux-wt` uses the agent's own hook events instead, so flagging is automatic,
precise, and knows `done` from `waiting`. tmux-notify's remote backends
(Telegram, Pushover) are a genuinely good idea and a likely future addition here.

## Install

Requires `tmux`, `git` >= 2.17 (for `git worktree move`), `fzf`, and `python3`
for the hook installer.

```sh
git clone https://github.com/Or-Priesender/tmux-wt ~/.local/share/tmux-wt
~/.local/share/tmux-wt/install.sh
```

That does three things, all of them re-runnable and all of them reversible with
`./uninstall.sh`:

1. symlinks `bin/wt` into `~/.local/bin`
2. writes the tmux block into your tmux config between
   `# >>> tmux-wt >>>` / `# <<< tmux-wt <<<` markers, replacing it if it is
   already there
3. registers the attention hook in `~/.claude/settings.json`

```
--prefix DIR       install the symlink into DIR/bin   (default: ~/.local)
--tmux-conf FILE   tmux config to edit                (default: autodetected)
--claude-dir DIR   agent config dir for the hook      (default: ~/.claude)
--no-bin / --no-tmux / --no-hook
```

Then reload tmux (`tmux source-file ~/.config/tmux/tmux.conf`) and restart your
agent so it picks up the hook.

### As a tmux plugin

```tmux
set -g @plugin 'Or-Priesender/tmux-wt'
```

TPM handles the bindings and points them at the plugin's own `bin/wt`, so no
symlink is needed. The attention hook still has to be installed once, because it
edits a file outside tmux:

```sh
~/.tmux/plugins/tmux-wt/install.sh --no-bin --no-tmux
```

Keys can be rebound before the `run` line in your config:

```tmux
set -g @wt-key-new 'w'
set -g @wt-key-jump 'W'
set -g @wt-key-attention 'e'
set -g @wt-key-next 'E'
```

### A note on your status bar

The block sets `window-status-format` so a flagged window shows a `!`. If your
theme or another plugin sets `window-status-format` **after** the tmux-wt block,
it wins and the `!` never appears. `install.sh` warns when it detects this. The
fix is to move the block to the end of your config. If you would rather keep
your own format, add `#{?@wt_attention,!,}` to it yourself and drop the two
`setw` lines from the block.

## Commands

| Command | What it does |
|---|---|
| `wt new <name> [--fetch]` | Create the worktree and branch, seed it, open a tmux window, start the agent. `--fetch` updates `origin` first. |
| `wt new` | fzf-pick a repo, then prompt for a name. An empty name gets a fish codename. |
| `wt ls [--all]` | List workspaces in this repo, or across every repo under `$WT_SCAN`. |
| `wt jump [--all]` | fzf-pick a workspace and switch to its tmux window, recreating the window if it was closed. |
| `wt attention [--next]` | Go to an agent that finished or is waiting. `--next` takes the longest-waiting one with no picker. |
| `wt rename <old> <new>` | Rename the workspace, the branch and the tmux window together. |
| `wt rm <name>` | Kill the window, remove the worktree, delete the branch if it is merged. |

### What `wt new` actually does

1. Branches from `origin/HEAD`, falling back to `origin/main` then
   `origin/master`. Some clones have no local `origin/HEAD`, hence the fallback.
2. Creates `$WT_ROOT/<repo>/<name>`.
3. Copies gitignored `.env*` files across from the main checkout, since those are
   exactly the files a fresh worktree needs and git will never bring them.
4. Runs `.worktree-setup` from the repo root if it exists and is executable, with
   the worktree as cwd and `$MAIN_REPO` pointing at the main checkout. Use it for
   `npm install`, symlinking a `node_modules`, whatever the repo needs.
5. Opens a tmux window named after the workspace and starts `$WT_AGENT` in it.

### Which repos `wt new` offers

With no arguments (which is what `prefix + a` runs) the picker lists the repos
you already have a tmux session for, labelled with that session, followed by
every other main checkout one level under `$WT_SCAN`, labelled `no session`. A
repo is listed once, deduped by its main worktree root, since a repo can have
several sessions and a session's cwd can point at a different repo.

That means a session manager like [tms](https://github.com/jrmoulton/tmux-sessionizer)
composes with this but is not required: sessions you already have float to a
useful label, and repos you have never opened are still reachable. Picking
either one creates the session if it does not exist.

Giving a name instead (`wt new my-task`) skips the picker entirely and uses the
repo you are currently in.

### Branch naming

A name matching `^[A-Z]+-[0-9]+` is used as the branch verbatim, so
`wt new PROJ-1234` gives you the branch `PROJ-1234` and any tooling that pulls an
issue key out of the branch name keeps working. Anything else is prefixed with
your slugified `git config user.name`, so `wt new parser-fix` gives
`jane-doe/parser-fix`. Override the prefix with `$WT_PREFIX`, or set it empty to
turn prefixing off.

If you already use a helper that runs `git checkout -b PROJ-1234` in the main
checkout, do not also run `wt new PROJ-1234`: `git worktree add` refuses a branch
that is already checked out somewhere. Use one or the other.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `WT_ROOT` | `~/dev/worktrees` | Where worktrees are created, as `$WT_ROOT/<repo>/<name>`. |
| `WT_SCAN` | `~/dev` | Where `wt ls --all` looks for repos (one level deep). |
| `WT_AGENT` | `claude` | The command started in each new window. |
| `WT_PREFIX` | from `git config user.name` | Branch name prefix. Empty disables it. |

Set them in your shell rc. For the tmux bindings to see them they must be in the
environment the tmux **server** inherited, so after changing them either restart
the server or use `tmux set-environment -g`.

## The attention hook

`hooks/wt-attention.sh` runs on your agent's `Stop` and `Notification` events. It
sets a `@wt_attention` window option (`done` or `waiting`) plus a timestamp, and
sends a macOS notification. If you are already looking at that window it does
nothing, because there is nothing to tell you and nowhere to return to.

`prefix + n` then reads those flags:

- nothing waiting: says so in the status line
- one waiting: jumps straight to it
- several: opens a popup with an fzf picker, previewing the tail of each pane

`prefix + N` skips the picker and takes the longest-waiting one, which is the
right key when you are draining a queue of finished agents.

The hook is registered in `~/.claude/settings.json` by merging into the existing
`hooks` block. Other tools' entries are never touched, and `uninstall.sh` removes
only ours. Only Claude Code is wired up today; other agents with a real hook
mechanism are a wanted addition.

If your agent is not Claude Code, point its equivalent of a "finished" and a
"needs input" event at:

```sh
~/.local/share/tmux-wt/hooks/wt-attention.sh done
~/.local/share/tmux-wt/hooks/wt-attention.sh waiting
```

## Embedded terminals will steal your session

Worth knowing before it happens to you. A common `.zshrc` pattern is to
auto-attach tmux on shell start:

```sh
[ -z "$TMUX" ] && exec tmux new-session -A -s default
```

Every embedded terminal then attaches to that same `default` session: Orca, the
VS Code terminal, an agent spawning a shell. They fight over its size and its
active window, and a terminal that closes takes the session's client with it.
Guard it:

```sh
# Auto-start tmux, but let embedded/agent terminals opt out so they do not
# attach to the shared "default" session.
if [ -z "$TMUX" ] && [ -n "$PS1" ] \
  && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] \
  && [ -z "$INSIDE_EMACS" ] && [ -z "$NO_AUTO_TMUX" ] \
  && [[ "$TERM_PROGRAM" != "vscode" ]]; then
  exec tmux new-session -A -s default
fi
```

Add whatever your own tools set (`$ORCA_PANE_KEY`, `$TERM_PROGRAM`), and use
`NO_AUTO_TMUX=1` as the manual escape hatch.

## Tests

```sh
./test/smoke.sh          # 60 assertions across all six subcommands
./test/smoke.sh --keep   # leave the sandbox up to poke at
```

It builds a throwaway git repo with a real `origin` and two throwaway tmux
servers on their own sockets. It never touches your real tmux server, your repos
or your settings. The header of the script documents the traps involved in
testing tmux tooling, several of which are not obvious.

## License

MIT. See [LICENSE](LICENSE).
