# shperl

A TUI for [`shpool`](https://github.com/shell-pool/shpool). Like [tdupes/shpiel](https://github.com/tdupes/shpiel) but even more enlightened — it's just perl.

[`shpool-table`](https://github.com/GeoffChurch/shpool-table) is shperl's counterpart in Rust.

`shperl` arranges your `shpool` sessions in a comely table. Select, create, kill, and attach to sessions with mere keystrokes. Upon detaching, you will find yourself back at the table. Starting/quitting `shperl` has no effect on your `shpool` sessions, so you can run `shperl` in multiple terminals or tmux panes.

## What it looks like (colors/highlighting in terminal)

```
                           shpool (3 sessions)
  name       created  active
*>acme -nw   2h       now
  stuxnet    2h       1m
* djt-miner  1d       3h
  j down   k up   spc attach   n new   d kill   D daemon   v vars   q quit
```

- `>` marks the selection.
- `*` marks attached sessions.

Press `v` to manage `shpool`'s template variables and their attached sessions.

```
                              variables (2)
 > coin   = djt   (1 session)
   editor = acme   (1 session)
  candidate values:
   djt
 > xmr
   xrp

  {coin} attachments:
    {coin}-miner             djt-miner        pid 4321  -> xmr-miner
  set coin = xmr_   (ret: apply, esc: cancel)
```

## Install

1. [Install `shpool`](https://github.com/shell-pool/shpool#installation)
2. Set your table with whatever flavor you like:

   - *L'amuse-bouche*

     ```bash
     perl -e "$(curl -fsSL https://raw.githubusercontent.com/GeoffChurch/shperl/main/shperl.pl)"
     ```

   - *Le plat de résistance*

     ```bash
     DEST=~/.local/bin/shperl
     curl -fLo "$DEST" https://raw.githubusercontent.com/GeoffChurch/shperl/main/shperl.pl
     chmod +x "$DEST"
     ```

## Usage

```
shperl [--config-file PATH] [--log-file PATH] [--socket PATH] [-v ...] [SESSION]
```

These flags are forwarded verbatim to every `shpool` invocation, so e.g. `shperl --socket /tmp/s2` manages sessions on a non-default daemon.

Given a `SESSION` name, `shperl` attaches to it straight away, skipping the table. This is exactly equivalent to starting `shperl` and pressing enter on that session's row — so detaching drops you into the table (rather than exiting), and a session that's attached elsewhere still asks before stealing it. A name that doesn't exist is an error, not an implicit create: use `n` for that, which is also what prompts for any template variables the name references.

Keys:

| key           | action                                                    |
|---------------|-----------------------------------------------------------|
| `j` / down    | select next                                               |
| `k` / up      | select previous                                           |
| space / enter | attach to selected session                                |
| `n`           | create new session (prompts for name)                     |
| `d`           | kill selected session (confirm with `y`)                  |
| `D`           | start `shpool` daemon if not running, then refresh        |
| `v`           | manage `shpool` template variables                  |
| `q` / `C-c`   | quit `shperl` (doesn't affect sessions)                   |

Detaching from a `shpool` session (`C-S C-q`, or however you've configured it) returns you to `shperl`.

The session list also auto-refreshes when the terminal regains focus, so switching back from another window picks up sessions added/killed elsewhere without a keystroke.

## How it works

- `shpool events` to subscribe to `shpool`'s events socket, so that `shperl` can refresh the table display at each event. Whenever the socket is unavailable, `shperl` falls back to refreshing upon keystrokes and terminal focus events.
- `shpool list --json` for the table display. The `D` binding runs the same call with `--daemonize`, which forks a daemon first if one isn't already running.
- `shpool attach <name>` for attach and create. `shperl` is stricter than `shpool` here because it checks if a session name already exists before creating it.
- `shpool kill <name>` for kill.
- `shpool var list` / `shpool var set <name> <value>` for the `v` variables view.
