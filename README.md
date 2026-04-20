# shperl

A TUI for [`shpool`](https://github.com/shell-pool/shpool). Like [tdupes/shpiel](https://github.com/tdupes/shpiel) but even more better — it's just perl.

`shperl` arranges your shpool sessions in a handsome table. Select, create, kill, and attach to sessions with mere keystrokes. Upon detaching, you will find yourself back at the table.

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

Drop it in your `$PATH` and make it executable:

```
curl -o ~/.local/bin/shperl https://raw.githubusercontent.com/GeoffChurch/shperl/main/shperl.pl
chmod +x ~/.local/bin/shperl
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

- `shpool list --json` for the model, refreshed after every keypress in normal mode.
- `shpool attach <name>` for attach and create. `shperl` is stricter than `shpool` here because it checks if a session name already exists before creating it.
- `shpool kill <name>` for kill.
