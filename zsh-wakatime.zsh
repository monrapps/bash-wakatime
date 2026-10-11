# wakatime for zsh
#
# include this file in your "~/.zshrc" file with this command:
#   source path/to/zsh-wakatime.zsh
#
# Don't forget to create and configure your "~/.wakatime.cfg" file.
#
# Same behavior as bash-wakatime.sh, on zsh's native preexec/precmd hooks and
# without Linux-only tools, so it runs on macOS too: a heartbeat is sent when a
# command starts and, while it keeps the terminal, every WAKATIME_ZSH_INTERVAL
# seconds as long as the terminal had keyboard input in the last
# WAKATIME_ZSH_IDLE seconds (read from the tty atime).

[[ -o interactive ]] || return 0

: ${WAKATIME_CLI:=$HOME/.wakatime/wakatime-cli}
: ${WAKATIME_ZSH_INTERVAL:=120}        # seconds between heartbeats of a running command
: ${WAKATIME_ZSH_IDLE:=900}            # stop counting after this long without keyboard input
: ${WAKATIME_ZSH_IGNORE:=claude codex} # programs already tracked by their own WakaTime plugin
: ${WAKATIME_ZSH_TODAY:=0}             # refresh $WAKATIME_TODAY for prompt themes every N seconds, 0 disables

# load only zstat: the full zsh/stat module also defines a `stat` builtin that shadows the real one
if ! zmodload zsh/datetime 2>/dev/null || ! zmodload -F zsh/stat b:zstat 2>/dev/null ||
   ! zmodload -F zsh/system b:zsystem 2>/dev/null; then
    print -u2 "zsh-wakatime: needs the zsh/datetime, zsh/stat and zsh/system modules"
    return 1
fi
if [[ ! -x $WAKATIME_CLI ]]; then
    print -u2 "zsh-wakatime: wakatime-cli not found at $WAKATIME_CLI"
    return 1
fi
if (( WAKATIME_ZSH_TODAY > 0 )) && ! (( $+commands[curl] && $+commands[jq] )); then
    print -u2 "zsh-wakatime: WAKATIME_ZSH_TODAY needs curl and jq, disabling it"
    WAKATIME_ZSH_TODAY=0
fi
[[ -n $TTY ]] || return 0

typeset -g __wt_version=2.0.0
typeset -g __wt_shell=$$ __wt_tty=$TTY
typeset -g __wt_last_key= __wt_ka_pid= __wt_cat=
typeset -gi __wt_last_sent=0 __wt_today_at=0
typeset -g __wt_today_file=${XDG_CACHE_HOME:-$HOME/.cache}/zsh-wakatime/today

__wt_ignored() {
    [[ " $WAKATIME_ZSH_IGNORE " == *" $1 "* ]]
}

# sets __wt_cat from a program name and its first argument
__wt_category() {
    case $1 in
        make|ninja)
            if [[ $2 == (test|check) ]]; then __wt_cat="running tests"; else __wt_cat=building; fi ;;
        cmake|meson|scons|bitbake|gcc|g++|cc|c++|clang|clang++|rustc|tsc|mvn|gradle|xcodebuild|swiftc)
            __wt_cat=building ;;
        pytest|jest|vitest|ctest|tox)
            __wt_cat="running tests" ;;
        gdb|gdb-multiarch|lldb|strace|ltrace|dtruss|valgrind|perf|openocd)
            __wt_cat=debugging ;;
        pio|platformio)
            case $2 in
                run) __wt_cat=building ;;
                test) __wt_cat="running tests" ;;
                *) __wt_cat=coding ;;
            esac ;;
        cargo|go|npm|pnpm|yarn|bun|docker|idf.py|west|dotnet|swift)
            case $2 in
                build|b|compile) __wt_cat=building ;;
                test|test:*|t) __wt_cat="running tests" ;;
                *) __wt_cat=coding ;;
            esac ;;
        *)
            __wt_cat=coding ;;
    esac
}

# entity category dir -- callers detach it with &! so killing the keepalive never cuts a send
__wt_send() {
    local -a out args
    out=("${(@f)$(git -C $3 rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)}")
    args=(--plugin "zsh/$ZSH_VERSION zsh-wakatime/$__wt_version" --entity-type app --entity $1 --category $2)
    if [[ -n $out[1] ]]; then
        args+=(--project ${out[1]:t})
        [[ -n $out[2] && $out[2] != HEAD ]] && args+=(--alternate-branch $out[2])
    else
        args+=(--project Terminal)
    fi
    $WAKATIME_CLI $args </dev/null >/dev/null 2>&1
}

# entity category dir -- detached, killed by __wt_precmd when the command ends
__wt_keepalive() {
    local entity=$1 cat=$2 s= fg comm a
    local -a at cmdv
    trap '[[ -n $s ]] && kill $s 2>/dev/null; exit 0' TERM
    while :; do
        sleep $WAKATIME_ZSH_INTERVAL & s=$!
        wait $s; s=
        kill -0 $__wt_shell 2>/dev/null || exit 0
        zstat -A at +atime -- $__wt_tty 2>/dev/null || at=(0)
        (( EPOCHSECONDS - at[1] < WAKATIME_ZSH_IDLE )) || continue
        # bill whatever holds the terminal now: covers `cd x && make`, aliases and scripts
        fg=${$(ps -o tpgid= -p $__wt_shell 2>/dev/null)//[[:space:]]/}
        if [[ -n $fg && $fg != $__wt_shell ]]; then
            comm=${${$(ps -o ucomm= -p $fg 2>/dev/null)//[[:space:]]/}:t}
            # an interpreter is billed as the script it runs: npm CLIs such as claude are node scripts
            if [[ $comm == (node|python*|ruby|perl|sh|bash|zsh) ]]; then
                cmdv=(${(z)$(ps -o command= -p $fg 2>/dev/null)})
                for a in $cmdv[2,-1]; do
                    [[ $a == -* ]] || { comm=${${a:t}%.*}; break }
                done
            fi
            if [[ -n $comm ]]; then
                __wt_ignored $comm && continue
                case $comm in
                    sudo|doas|env|time|nice|nohup|timeout|xargs|bash|sh|zsh|"$entity") ;;
                    *) entity=$comm; __wt_category $comm ""; cat=$__wt_cat ;;
                esac
            fi
        fi
        __wt_send $entity $cat $3 &!
    done
}

# preexec gets the command line with aliases expanded in $3
__wt_preexec() {
    local -a words
    local i=1 prog sub
    words=(${(z)3})
    while [[ $words[i] == *=* || $words[i] == -* || $words[i] == (sudo|doas|env|command|builtin|exec|nohup|time|nice|noglob|nocorrect) ]]; do
        (( i++ ))
    done
    prog=${${(Q)words[i]}:t}
    if [[ -z $prog ]] || __wt_ignored $prog; then
        return
    fi
    sub=${(Q)words[i+1]}
    [[ $prog == (npm|pnpm|yarn|bun) && $sub == run ]] && sub=${(Q)words[i+2]}
    __wt_category $prog $sub
    # same rule as the editor plugins: new entity, or the last heartbeat is old enough
    if [[ "$prog|$__wt_cat|$PWD" != "$__wt_last_key" ]] || (( EPOCHSECONDS - __wt_last_sent >= WAKATIME_ZSH_INTERVAL )); then
        __wt_last_key="$prog|$__wt_cat|$PWD"
        __wt_last_sent=$EPOCHSECONDS
        __wt_send $prog $__wt_cat $PWD </dev/null >/dev/null 2>&1 &!
    fi
    __wt_keepalive $prog $__wt_cat $PWD </dev/null >/dev/null 2>&1 &!
    __wt_ka_pid=$!
}

# seconds -- prints 2h05m, 32m or 41s
__wt_fmt() {
    if (( $1 >= 3600 )); then
        printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60))
    elif (( $1 >= 60 )); then
        printf '%dm' $(($1 / 60))
    else
        printf '%ds' $1
    fi
}

# writes today's total and shell (Bash + Zsh editors) time to __wt_today_file -- detached,
# and at most one fetch per WAKATIME_ZSH_TODAY seconds across every open shell
__wt_today_refresh() {
    local dir=${__wt_today_file:h} cfg=${WAKATIME_HOME:-$HOME}/.wakatime.cfg key url json total shell lfd
    local -a mt
    mkdir -p $dir && : >> $dir/lock && zsystem flock -t 0 -f lfd $dir/lock || return
    zstat -A mt +mtime -- $__wt_today_file 2>/dev/null || mt=(0)
    (( EPOCHSECONDS - mt[1] < WAKATIME_ZSH_TODAY )) && return
    key=$(sed -n 's/^[[:space:]]*api_key[[:space:]]*=[[:space:]]*//p' $cfg | tr -d '[:space:]')
    url=$(sed -n 's/^[[:space:]]*api_url[[:space:]]*=[[:space:]]*//p' $cfg | tr -d '[:space:]')
    [[ -n $key ]] || return
    # the key goes through curl's stdin config, never argv, where any user could read it in ps
    json=$(print -r -- "header = \"Authorization: Basic $(print -rn -- $key | base64 | tr -d '\n')\"" |
           curl -sf -m 10 -K - "${url:-https://api.wakatime.com/api/v1}/users/current/summaries?start=today&end=today") || return
    read -r total shell < <(jq -r '[.cumulative_total.seconds,
        ([.data[0].editors[]? | select(.name | test("^(bash|zsh)$"; "i")) | .total_seconds] | add // 0)] | map(floor) | @tsv' <<< $json) || return
    { __wt_fmt $total; print; __wt_fmt $shell; print } > $__wt_today_file.$$ && mv -f $__wt_today_file.$$ $__wt_today_file
}

__wt_precmd() {
    if [[ -n $__wt_ka_pid ]]; then
        kill $__wt_ka_pid 2>/dev/null
        __wt_ka_pid=
    fi
    if (( WAKATIME_ZSH_TODAY > 0 )); then
        { read -r WAKATIME_TODAY; read -r WAKATIME_TODAY_SHELL } 2>/dev/null < $__wt_today_file
        export WAKATIME_TODAY WAKATIME_TODAY_SHELL
        if (( EPOCHSECONDS - __wt_today_at >= 60 )); then
            __wt_today_at=$EPOCHSECONDS
            __wt_today_refresh </dev/null >/dev/null 2>&1 &!
        fi
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __wt_preexec
add-zsh-hook precmd __wt_precmd
