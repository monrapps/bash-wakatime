BASH and ZSH plugin for wakatime
================================

Automatic time tracking for commands in BASH and ZSH using [wakatime](http://wakatime.com/).

Installation
------------

Make sure you have configured wakatime API key in your [~/.wakatime.cfg](https://github.com/wakatime/wakatime-cli/blob/develop/USAGE.md#ini-config-file) file.

1. Run `./install_cli.sh` to install the [WakaTime CLI](https://github.com/wakatime/wakatime-cli).

2. For bash users (bash >= 5):
  - git clone https://github.com/irondoge/bash-wakatime.git

  - include the "bash-wakatime.sh" file in your "~/.bashrc" file with this command:

    `. path/to/bash-wakatime.sh`

  - or this command:

    `source path/to/bash-wakatime.sh`

  - It must be sourced: running the file as a program only hooks a child shell
    that exits right away, so the script refuses to run that way.

   For zsh users (macOS default shell included), add this to "~/.zshrc" instead:

    `source path/to/zsh-wakatime.zsh`

3. Open a new terminal and type commands

4. Visit https://wakatime.com/dashboard

How it works
------------

- A heartbeat is sent when a command starts. The program name is the entity
  (`--entity-type app`), never the full command line, so arguments and secrets
  stay local.
- While a command keeps the terminal (builds, `ssh`, `vim`, serial consoles),
  a heartbeat is sent every `WAKATIME_BASH_INTERVAL` seconds, billed to the
  process that holds the terminal at that moment (`cd x && make` counts as
  `make`). Long commands are no longer lost to the WakaTime timeout.
- Those heartbeats stop once the terminal has had no keyboard input for
  `WAKATIME_BASH_IDLE` seconds, read from the tty atime (the same source `w`
  uses for IDLE), so an idle `ssh` or `htop` left open overnight is not billed.
- Project is the git toplevel name with its branch, or `Terminal` outside a repo.
- Category is guessed from the command: `make`, `cargo build`, `npm run build`,
  `pio run`... are `building`; `make test`, `pytest`, `cargo test`... are
  `running tests`; `gdb`, `strace`, `valgrind`, `openocd`... are `debugging`;
  everything else is `coding`. Edit `__wt_category` to change the mapping.
- Hooks: `PS0` flags a non-empty command line, a self-disarming `DEBUG` trap
  catches its first simple command (preexec), and `PROMPT_COMMAND` stops the
  keepalive and re-arms the trap (precmd). It refuses to install over a
  `DEBUG` trap set by another tool, such as bash-preexec.

zsh
---

`zsh-wakatime.zsh` behaves the same on zsh's native `preexec`/`precmd` hooks
and avoids Linux-only tools, so it also runs on macOS: `zstat` for the tty
atime and cache mtime, `zsystem flock` for the lock, `ps` for the foreground
process (an interpreter such as `node` is billed as the script it runs, since
npm CLIs like `claude` are node scripts). Aliases are expanded before the
entity is picked. It loads only the `zstat` builtin, never the full
`zsh/stat` module, whose `stat` builtin would shadow the system command.

Its variables mirror the bash ones with a `ZSH` infix: `WAKATIME_ZSH_INTERVAL`,
`WAKATIME_ZSH_IDLE`, `WAKATIME_ZSH_IGNORE` and `WAKATIME_ZSH_TODAY` (which
needs `curl` and `jq`). `WAKATIME_CLI` is shared.

Configuration
-------------

Set these before sourcing the script:

| Variable | Default | Meaning |
|---|---|---|
| `WAKATIME_CLI` | `~/.wakatime/wakatime-cli` | wakatime-cli binary |
| `WAKATIME_BASH_INTERVAL` | `120` | seconds between heartbeats of a running command |
| `WAKATIME_BASH_IDLE` | `900` | stop billing a running command after this long without keyboard input |
| `WAKATIME_BASH_IGNORE` | `claude codex` | space-separated programs that already have their own WakaTime plugin, [Claude Code](https://wakatime.com/claude-code) and [Codex CLI](https://wakatime.com/codex) by default (add `vim` if you use vim-wakatime) |
| `WAKATIME_BASH_TODAY` | `0` | refresh today's totals for the prompt every this many seconds, `0` disables (needs `curl`, `jq` and `flock`) |

Today's time in the prompt
--------------------------

With `WAKATIME_BASH_TODAY` set, a detached job fetches today's
[summaries](https://wakatime.com/developers#summaries) at most once per
interval across all open shells (`flock` plus the cache file mtime), and each
prompt reads the cache with no fork and exports:

- `WAKATIME_TODAY`: today's total across every editor, e.g. `2h05m`
- `WAKATIME_TODAY_SHELL`: the part of it tracked by the shell plugins (the
  `Bash` and `Zsh` editors), e.g. `41m`

The prompt never waits on the network, and the API key is read from
`~/.wakatime.cfg` (`api_url` is honored) and passed to curl through stdin,
never on its command line.

`themes/matrix.omp.json` is an [oh-my-posh](https://ohmyposh.dev) theme that
shows both values (it needs a Nerd Font). Init oh-my-posh before this script:

```bash
eval "$(oh-my-posh init bash --config path/to/bash-wakatime/themes/matrix.omp.json)"
WAKATIME_BASH_TODAY=300
source path/to/bash-wakatime/bash-wakatime.sh
```

For zsh, use `oh-my-posh init zsh`, `WAKATIME_ZSH_TODAY=300` and
`source path/to/bash-wakatime/zsh-wakatime.zsh` in `~/.zshrc`. The theme's
transient prompt only takes effect in zsh (bash needs ble.sh).

Any other prompt can use the variables too, e.g.
`PS1='${WAKATIME_TODAY:+[$WAKATIME_TODAY] }\w \$ '`.

oh-my-posh's built-in `wakatime` segment works as well, but bash has no
streaming mode, so every cache miss blocks the prompt for the whole API
round trip (about a second).

Compatibility with prompt frameworks (bash only; zsh already restores `$?` and
`pipestatus` for every precmd hook): the hook re-appends its `PS0` flag on
every prompt (oh-my-posh assigns `PS0` when it initializes), and saves the
user's `PIPESTATUS` in `BP_PIPESTATUS`, which oh-my-posh reads, so its status
segment still sees the real pipeline status even though this hook runs first.
