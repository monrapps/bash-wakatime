# wakatime for bash
#
# include this file in your "~/.bashrc" file with this command:
#   . path/to/bash-wakatime.sh
#
# or this command:
#   source path/to/bash-wakatime.sh
#
# Don't forget to create and configure your "~/.wakatime.cfg" file.
#
# A heartbeat is sent when a command starts and, while it keeps the terminal,
# every WAKATIME_BASH_INTERVAL seconds as long as the terminal had keyboard
# input in the last WAKATIME_BASH_IDLE seconds (read from the tty atime, the
# same source `w` uses for IDLE). Requires bash >= 5.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "bash-wakatime: this file must be sourced, not executed: source $0" >&2
    exit 1
fi

[[ $- == *i* ]] || return 0

: "${WAKATIME_CLI:=$HOME/.wakatime/wakatime-cli}"
: "${WAKATIME_BASH_INTERVAL:=120}"  # seconds between heartbeats of a running command
: "${WAKATIME_BASH_IDLE:=900}"      # stop counting after this long without keyboard input
: "${WAKATIME_BASH_IGNORE:=claude}" # programs already tracked by their own WakaTime plugin

if (( BASH_VERSINFO[0] < 5 )); then
    echo "bash-wakatime: bash >= 5 required, found $BASH_VERSION" >&2
    return 1
fi
if [[ ! -x $WAKATIME_CLI ]]; then
    echo "bash-wakatime: wakatime-cli not found at $WAKATIME_CLI" >&2
    return 1
fi
__wt_trap=$(trap -p DEBUG)
if [[ -n $__wt_trap && $__wt_trap != *__wt_preexec* ]]; then
    echo "bash-wakatime: a DEBUG trap is already set ($__wt_trap), not installing" >&2
    return 1
fi
__wt_tty=$(tty 2>/dev/null) || return 0

__wt_version="2.0.0"
# the trap disarms itself inline (doing it inside __wt_preexec doesn't stick for the running
# command) and __wt_precmd re-arms it, so loops typed at the prompt don't pay for it
__wt_debug='(( __wt_pending )) && { trap - DEBUG; __wt_preexec; }'
__wt_shell=$$
__wt_pending=0
__wt_last_key=
__wt_last_sent=0
__wt_ka_pid=

__wt_ignored() {
    [[ " $WAKATIME_BASH_IGNORE " == *" $1 "* ]]
}

# sets __wt_cat from a program name and its first argument
__wt_category() {
    case $1 in
        make|ninja)
            if [[ $2 == test || $2 == check ]]; then __wt_cat="running tests"; else __wt_cat=building; fi ;;
        cmake|meson|scons|bitbake|gcc|g++|cc|c++|clang|clang++|rustc|tsc|mvn|gradle)
            __wt_cat=building ;;
        pytest|jest|vitest|ctest|tox)
            __wt_cat="running tests" ;;
        gdb|gdb-multiarch|lldb|strace|ltrace|valgrind|perf|openocd)
            __wt_cat=debugging ;;
        pio|platformio)
            case $2 in
                run) __wt_cat=building ;;
                test) __wt_cat="running tests" ;;
                *) __wt_cat=coding ;;
            esac ;;
        cargo|go|npm|pnpm|yarn|bun|docker|idf.py|west|dotnet)
            case $2 in
                build|b|compile) __wt_cat=building ;;
                test|test:*|t) __wt_cat="running tests" ;;
                *) __wt_cat=coding ;;
            esac ;;
        *)
            __wt_cat=coding ;;
    esac
}

# entity category dir -- callers detach it with ( ... & ) so killing the keepalive never cuts a send
__wt_send() {
    local top branch
    { read -r top; read -r branch; } < <(git -C "$3" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
    local -a args=(--plugin "bash/${BASH_VERSION%%(*} bash-wakatime/$__wt_version"
                   --entity-type app --entity "$1" --category "$2")
    if [[ -n $top ]]; then
        args+=(--project "${top##*/}")
        [[ -n $branch && $branch != HEAD ]] && args+=(--alternate-branch "$branch")
    else
        args+=(--project Terminal)
    fi
    "$WAKATIME_CLI" "${args[@]}" </dev/null >/dev/null 2>&1
}

# entity category dir -- detached, killed by __wt_precmd when the command ends
__wt_keepalive() {
    local entity=$1 cat=$2 s= stat fg comm
    trap '[[ -n $s ]] && kill "$s" 2>/dev/null; exit 0' TERM
    while :; do
        sleep "$WAKATIME_BASH_INTERVAL" & s=$!
        wait "$s"; s=
        kill -0 "$__wt_shell" 2>/dev/null || exit 0
        (( EPOCHSECONDS - $(stat -c %X "$__wt_tty" 2>/dev/null || echo 0) < WAKATIME_BASH_IDLE )) || continue
        # bill whatever holds the terminal now: covers `cd x && make`, aliases and scripts
        stat=$(<"/proc/$__wt_shell/stat")
        read -r _ _ _ _ _ fg _ <<< "${stat##*") "}"
        if (( fg != __wt_shell )) && read -r comm < "/proc/$fg/comm"; then
            __wt_ignored "$comm" && continue
            case $comm in
                sudo|doas|env|time|nice|nohup|timeout|xargs|bash|sh|"$entity") ;;
                *) entity=$comm; __wt_category "$comm" ""; cat=$__wt_cat ;;
            esac
        fi
        (__wt_send "$entity" "$cat" "$3" &)
    done
}

# runs from the DEBUG trap on the first simple command after PS0, i.e. once per command line
__wt_preexec() {
    __wt_pending=0
    [[ $BASH_COMMAND == __wt_* ]] && return
    local -a words
    local i=0 prog sub
    read -ra words <<< "$BASH_COMMAND"
    while [[ ${words[i]} == *=* || ${words[i]} == -* || ${words[i]} =~ ^(sudo|doas|env|command|builtin|exec|nohup|time|nice)$ ]]; do
        (( i++ ))
    done
    prog=${words[i]##*/}
    if [[ -z $prog ]] || __wt_ignored "$prog"; then
        return
    fi
    sub=${words[i+1]}
    [[ $prog =~ ^(npm|pnpm|yarn|bun)$ && $sub == run ]] && sub=${words[i+2]}
    __wt_category "$prog" "$sub"
    # same rule as the editor plugins: new entity, or the last heartbeat is old enough
    if [[ "$prog|$__wt_cat|$PWD" != "$__wt_last_key" ]] || (( EPOCHSECONDS - __wt_last_sent >= WAKATIME_BASH_INTERVAL )); then
        __wt_last_key="$prog|$__wt_cat|$PWD"
        __wt_last_sent=$EPOCHSECONDS
        (__wt_send "$prog" "$__wt_cat" "$PWD" </dev/null >/dev/null 2>&1 &)
    fi
    __wt_ka_pid=$(__wt_keepalive "$prog" "$__wt_cat" "$PWD" </dev/null >/dev/null 2>&1 & echo $!)
}

__wt_precmd() {
    local s=$?
    if [[ -n $__wt_ka_pid ]]; then
        kill "$__wt_ka_pid" 2>/dev/null
        __wt_ka_pid=
    fi
    trap "$__wt_debug" DEBUG
    return $s
}

# PS0 is expanded only for non-empty command lines, right before they run; the
# arithmetic inside the substring offset sets the flag in this shell, no subshell
[[ $PS0 == *__wt_pending* ]] || PS0+='${PS0:0:$((__wt_pending=1,0))}'
[[ $PROMPT_COMMAND == *__wt_precmd* ]] || PROMPT_COMMAND="__wt_precmd"${PROMPT_COMMAND:+$'\n'$PROMPT_COMMAND}
trap "$__wt_debug" DEBUG
