# shperl

A TUI for [`shpool`](https://github.com/shell-pool/shpool). Like [tdupes/shpiel](https://github.com/tdupes/shpiel) but even more better — it's just perl.

Vibe-ported from the vibe-coded [GeoffChurch/shpool-table](https://github.com/GeoffChurch/shpool-table), which is written in Rust to match `shpool`.

`shperl` arranges your shpool sessions in a handsome table. Select, create, kill, and attach to sessions with mere keystrokes. Upon detaching, you will find yourself back at the table. Starting/quitting `shperl` has no effect on your `shpool` sessions, so you can run `shperl` in multiple terminals or tmux panes.

## What it looks like (colors/highlighting in terminal)

```
                  shpool (3 sessions)
  name       created  active
 >acme -nw   2h       now
  stuxnet    2h       1m
* djt-miner  1d       3h
  j down   k up   spc attach   n new   d kill   q quit
```

- `>` marks the selection.
- `*` marks attached sessions.

## Install

First, [install](https://github.com/shell-pool/shpool#installation) `shpool`.

Trial run for commitment-phobes:
```bash
perl -e "$(curl -fsSL https://raw.githubusercontent.com/GeoffChurch/shperl/main/shperl.pl)"
```

Full install:
```bash
DEST=~/.local/bin/shperl
curl -fLo "$DEST" https://raw.githubusercontent.com/GeoffChurch/shperl/main/shperl.pl
chmod +x "$DEST"
```

## Usage

```
shperl
```

Keys:

| key           | action                                   |
|---------------|------------------------------------------|
| `j` / down    | select next                              |
| `k` / up      | select previous                          |
| space / enter | attach to selected session               |
| `n`           | create new session (prompts for name)    |
| `d`           | kill selected session (confirm with `y`) |
| `q` / `C-c`   | quit `shperl` (doesn't affect sessions)  |

Detaching from a `shpool` session (`C-S C-q`, or however you've configured it) returns you to `shperl`.

## How it works

- `shpool list --json` for the table display, refreshed after every keypress in normal mode.
- `shpool attach <name>` for attach and create. `shperl` is stricter than `shpool` here because it checks if a session name already exists before creating it.
- `shpool kill <name>` for kill.
