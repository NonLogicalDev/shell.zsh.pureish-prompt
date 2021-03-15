# Pure (Modified by Oleg Utkin) (original by Sindre Sorhus)
# MIT License

# For my own and others sanity
################################################################################

# git:
# %b => current branch
# %a => current action (rebase/merge)

# prompt:
# %F => color dict
# %f => reset color
# %~ => current path
# %* => time
# %n => username
# %m => shortname host
# %(?..) => prompt conditional - %(condition.true.false)

# terminal codes:
# \e7   => save cursor position
# \e[2A => move cursor 2 lines up
# \e[1G => go to position 1 in terminal
# \e8   => restore cursor position
# \e[K  => clears everything after the cursor on the current line
# \e[2K => clear everything on the current line

# ENV VARIABLES DECLARATION:
################################################################################

pure_var_prompt_delimiter() {
    echo ${PURE_PROMPT_DELIMITER:-" "}
}
pure_var_vcs_prompt_delimiter() {
    echo ${PURE_PROMPT_VCS_DELIMITER:-":"}
}
pure_var_prompt_symbol() {
    echo ${PURE_PROMPT_SYMBOL:-❯}
}
pure_var_prompt_symbol_alt () {
    echo ${PURE_PROMPT_VICMD_SYMBOL:-❮}
}
pure_var_eol_mark() {
    echo ${PURE_PROMPT_EOL_MARK:-"\n"}
}

#-------------------------------------------------------------------------------

pure_var_max_exec_time() {
    echo ${PURE_CMD_MAX_EXEC_TIME:-5}
}

pure_var_git_delay_dirty_check () {
    echo ${PURE_GIT_DELAY_DIRTY_CHECK:-18000}
}

# SETUP:
################################################################################

prompt_pure_init_dependencies() {
    # Prevent percentage showing up if output doesn't end with a newline.
    export PROMPT_EOL_MARK=$(pure_var_eol_mark)

    prompt_opts=(subst percent)

    # borrowed from promptinit, sets the prompt options in case pure was not
    # initialized via promptinit.
    setopt noprompt{bang,cr,percent,subst} "prompt${^prompt_opts[@]}"

    if [[ -z $prompt_newline ]]; then
        # This variable needs to be set, usually set by promptinit.
        typeset -g prompt_newline=$'\n%{\r%}'
    fi

    zmodload zsh/datetime
    zmodload zsh/zle
    zmodload zsh/parameter

    autoload -Uz add-zsh-hook
    autoload -Uz vcs_info
    autoload -Uz async && async

    # The add-zle-hook-widget function is not guaranteed
    # to be available, it was added in Zsh 5.3.
    autoload -Uz +X add-zle-hook-widget 2>/dev/null
}

prompt_pure_setup() {
    prompt_pure_init_dependencies

    # Add command lifecycle hooks.
    add-zsh-hook precmd prompt_pure_precmd
    add-zsh-hook preexec prompt_pure_preexec

    # Setup and prime the prompt state. (Find user/env details)
    prompt_pure_state_setup

    # Hooking up to VIM mode.
    zle -N prompt_pure_update_vim_prompt_widget
    zle -N prompt_pure_reset_vim_prompt_widget
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget zle-line-finish prompt_pure_reset_vim_prompt_widget
        add-zle-hook-widget zle-keymap-select prompt_pure_update_vim_prompt_widget
    fi

    # if a virtualenv is activated, display it in grey
    PROMPT='%(12V.%F{242}%12v%f .)'

    # prompt turns red if the previous command didn't exit with 0
    PROMPT+='%(?.%F{magenta}.%F{red})${prompt_pure_state[prompt]}%f '

    # Store prompt expansion symbols for in-place expansion via (%). For
    # some reason it does not work without storing them in a variable first.
    typeset -ga prompt_pure_debug_depth
    prompt_pure_debug_depth=('%e' '%N' '%x')

    # Compare is used to check if %N equals %x. When they differ, the main
    # prompt is used to allow displaying both file name and function. When
    # they match, we use the secondary prompt to avoid displaying duplicate
    # information.
    local -A ps4_parts
    ps4_parts=(
        depth 	  '%F{yellow}${(l:${(%)prompt_pure_debug_depth[1]}::+:)}%f'
        compare   '${${(%)prompt_pure_debug_depth[2]}:#${(%)prompt_pure_debug_depth[3]}}'
        main      '%F{blue}${${(%)prompt_pure_debug_depth[3]}:t}%f%F{242}:%I%f %F{242}@%f%F{blue}%N%f%F{242}:%i%f'
        secondary '%F{blue}%N%f%F{242}:%i'
        prompt 	  '%F{242}>%f '
    )
    # Combine the parts with conditional logic. First the `:+` operator is
    # used to replace `compare` either with `main` or an empty string. Then
    # the `:-` operator is used so that if `compare` becomes an empty
    # string, it is replaced with `secondary`.
    local ps4_symbols='${${'${ps4_parts[compare]}':+"'${ps4_parts[main]}'"}:-"'${ps4_parts[secondary]}'"}'

    # Improve the debug prompt (PS4), show depth by repeating the +-sign and
    # add colors to highlight essential parts like file and function name.
    PROMPT4="${ps4_parts[depth]} ${ps4_symbols}${ps4_parts[prompt]}"

    unset ZSH_THEME  # Guard against Oh My Zsh themes overriding Pure.
}

prompt_pure_state_setup() {
    setopt localoptions noshwordsplit

    # Check SSH_CONNECTION and the current state.
    local ssh_connection=${SSH_CONNECTION:-$PROMPT_PURE_SSH_CONNECTION}
    local username
    if [[ -z $ssh_connection ]] && (( $+commands[who] )); then
        # When changing user on a remote system, the $SSH_CONNECTION
        # environment variable can be lost, attempt detection via who.
        local who_out
        who_out=$(who -m 2>/dev/null)
        if (( $? )); then
            # Who am I not supported, fallback to plain who.
            local -a who_in
            who_in=( ${(f)"$(who 2>/dev/null)"} )
            who_out="${(M)who_in:#*[[:space:]]${TTY#/dev/}[[:space:]]*}"
        fi

        local reIPv6='(([0-9a-fA-F]+:)|:){2,}[0-9a-fA-F]+'  # Simplified, only checks partial pattern.
        local reIPv4='([0-9]{1,3}\.){3}[0-9]+'   # Simplified, allows invalid ranges.
        # Here we assume two non-consecutive periods represents a
        # hostname. This matches foo.bar.baz, but not foo.bar.
        local reHostname='([.][^. ]+){2}'

        # Usually the remote address is surrounded by parenthesis, but
        # not on all systems (e.g. busybox).
        local -H MATCH MBEGIN MEND
        if [[ $who_out =~ "\(?($reIPv4|$reIPv6|$reHostname)\)?\$" ]]; then
            ssh_connection=$MATCH

            # Export variable to allow detection propagation inside
            # shells spawned by this one (e.g. tmux does not always
            # inherit the same tty, which breaks detection).
            export PROMPT_PURE_SSH_CONNECTION=$ssh_connection
        fi
        unset MATCH MBEGIN MEND
    fi

    # show username@host if logged in through SSH
    if [[ -n $ssh_connection ]]; then
        username='%F{242}%n@%m%f'
    fi

    # show username@host if root, with username in white
    if [[ $UID -eq 0 ]]; then
        username='%F{white}%n%f%F{242}@%m%f'
    fi

    typeset -gA prompt_pure_state
    prompt_pure_state=(
        username "$username"
    )

    # Ensure prompt state gets initialized with symbol.
    prompt_pure_reset_prompt_symbol
}

prompt_pure_reset_prompt_symbol() {
    setopt localoptions noshwordsplit

    prompt_pure_state[prompt]=$(pure_var_prompt_symbol)
}

prompt_pure_reset_vim_prompt_widget() {
    setopt localoptions noshwordsplit

    prompt_pure_reset_prompt_symbol
    zle && zle .reset-prompt
}

prompt_pure_update_vim_prompt_widget() {
    setopt localoptions noshwordsplit

    if [[ $KEYMAP == "vicmd" ]]; then
        prompt_pure_state[prompt]=$(pure_var_prompt_symbol_alt)
    else #(main|viins) etc.
        prompt_pure_state[prompt]=$(pure_var_prompt_symbol)
    fi
    zle && zle .reset-prompt
}

prompt_pure_vcs_prompt_render() {
    setopt localoptions noshwordsplit

    typeset -gA prompt_pure_vcs_info
    local -a vcs_prompt_parts
    local delim=$(pure_var_vcs_prompt_delimiter)

    # Set color for git branch/dirty status, change color if dirty checking has
    # been delayed.
    local git_color=yellow
    [[ -n ${prompt_pure_git_last_dirty_check_timestamp+x} ]] && git_color=red

    # VCS & Branch name.
    if [[ -n $prompt_pure_vcs_info[branch] ]]; then
        local -a branch_info=(
            "%F{$git_color}"'${prompt_pure_vcs_info[vcs]}%f'
            '$(pure_var_vcs_prompt_delimiter)'
            '%F{green}${prompt_pure_vcs_info[branch]}%f'
        )
        vcs_prompt_parts+=(${(j::)branch_info})
    fi

    # Is repo dirty.
    if [[ -n ${prompt_pure_vcs_info[dirty]} ]]; then
        vcs_prompt_parts+=("%F{red}&%f")
    fi

    # Stash presence.
    if [[ -n ${prompt_pure_vcs_info[stash]} ]]; then
        vcs_prompt_parts+=("%F{blue}@%f")
    fi

    # Repo pull/push arrows.
    if [[ -n $prompt_pure_vcs_info[sync_status] ]]; then
        vcs_prompt_parts+=('%F{magenta}(${prompt_pure_vcs_info[sync_status]})%f')
    fi

    # VCS Action.
    if [[ -n $prompt_pure_vcs_info[action] ]]; then
        vcs_prompt_parts+=('%F{red}(${prompt_pure_vcs_info[action]})%f')
    fi

    local -a vcs_prompt_full

    # Assembling and adding the VCS Prompt.
    if [[ -n $vcs_prompt_parts ]]; then
        vcs_prompt_full+=('%f{'"${(j($(pure_var_vcs_prompt_delimiter)))vcs_prompt_parts}"'%f}')
    fi

    # Stacked Git Section.
    if [[ -n ${prompt_pure_vcs_info[stg_top]} ]]; then
        local status_color="green"
        local -a stg_info

        if [[ -n ${prompt_pure_vcs_info[stg_broken]} ]]; then
            status_color="red"
        fi

        # Is repo dirty.
        if [[ -n ${prompt_pure_vcs_info[dirty]} ]]; then
            status_color="yellow"
        fi

        if [[ -n ${prompt_pure_vcs_info[stg_stack_place]} ]]; then
            stg_info=(
                # "%F{$git_color}"'stg%f'
                "stg"
                "%F{$status_color}"'${prompt_pure_vcs_info[stg_top]}%f'
                '${prompt_pure_vcs_info[stg_stack_place]}/${prompt_pure_vcs_info[stg_stack_total]}'
            )
        fi
        vcs_prompt_full+=('%f{'"${(j.:.)stg_info}"'%f}')
    fi

    echo "$vcs_prompt_full"
}

prompt_pure_parent_process() {
    basename "$(ps -o command= -p $(ps -o ppid= -p $$) | sed 's/ .*$//')"
}

prompt_pure_preprompt_render() {
    setopt localoptions noshwordsplit

    # Initialize the preprompt array.
    local -a preprompt_parts
    local -a preprompt_parts_extra

    preprompt_parts+=('($(prompt_pure_parent_process))')

    # Set the path.
    # preprompt_parts+=('%F{blue}%~%f')

    # Add current working dir:
    preprompt_parts+=('%F{yellow}(%F{blue}$(prompt_pure_shrink_path -f)%F{yellow})%f')


    # Adding Execution time.
    if [[ -n $prompt_pure_cmd_exec_time ]]; then
      preprompt_parts+=('%F{yellow}${prompt_pure_cmd_exec_time}%f')
    fi

    # Adding Timestamp:
    preprompt_parts+=('%f[$(date +"%T %D")]%f')

    # Adding Username and machine, if applicable.
    if [[ -n $prompt_pure_state[username] ]]; then
        preprompt_parts+=('${prompt_pure_state[username]}')
    fi

    local cleaned_ps1=$PROMPT
    if [[ $PROMPT = *$prompt_newline* ]]; then
        # Remove everything from the prompt until the newline. This
        # removes the preprompt and only the original PROMPT remains.
        cleaned_ps1=${PROMPT##*${prompt_newline}}
    fi

    # VCS Info:
    local vcs_prompt=$(prompt_pure_vcs_prompt_render)
    if [[ -n $vcs_prompt ]]; then
        preprompt_parts_extra+=("$vcs_prompt")
    fi

    # Construct the new prompt with a clean preprompt.
    local -ah ps1

    if (( ${#preprompt_parts_extra[@]} )); then
        ps1+=(
            ":: "
            "${(j.$(pure_var_prompt_delimiter).)preprompt_parts_extra}"
            $prompt_newline
        )
    fi

    ps1+=(
        ":: "
        "%(?::%F{red}[%?] %f)"
        "${(j.$(pure_var_prompt_delimiter).)preprompt_parts}"  # Join parts, space separated.
        $prompt_newline           # Separate preprompt and prompt.
        $cleaned_ps1
    )

    PROMPT="${(j..)ps1}"

    # Expand the prompt for future comparision.
    local expanded_prompt
    expanded_prompt="${(S%%)PROMPT}"

    if [[ $1 == precmd ]]; then
        # Initial newline, for spaciousness.
        print
    elif [[ $prompt_pure_last_prompt != $expanded_prompt ]]; then
        # Redraw the prompt.
        zle && zle .reset-prompt
    fi

    typeset -g prompt_pure_last_prompt=$expanded_prompt
}

prompt_pure_check_git_arrows() {
    setopt localoptions noshwordsplit

    local arrows left=${1:-0} right=${2:-0}

    (( right > 0 )) && arrows+=${PURE_GIT_DOWN_ARROW:-+r}
    (( left > 0 )) && arrows+=${PURE_GIT_UP_ARROW:-+l}

    [[ -n $arrows ]] || return
    typeset -g REPLY=$arrows
}

# HOOKS:
################################################################################

# Executed just after a command has been read and is about to be executed.
prompt_pure_preexec() {
    setopt localoptions noshwordsplit

    typeset -g prompt_pure_cmd_timestamp=$EPOCHSECONDS

    # shows the current dir and executed command in the title while a process is active
    prompt_pure_set_title 'ignore-escape' "$PWD:t: $2"

    # Disallow python virtualenv from updating the prompt, set it to 12 if
    # untouched by the user to indicate that Pure modified it. Here we use
    # magic number 12, same as in psvar.
    export VIRTUAL_ENV_DISABLE_PROMPT=${VIRTUAL_ENV_DISABLE_PROMPT:-12}
}

# Executed before each prompt.
prompt_pure_precmd() {
    setopt localoptions noshwordsplit

    # check exec time and store it in a variable
    prompt_pure_check_cmd_exec_time
    unset prompt_pure_cmd_timestamp

    # shows the full path in the title
    prompt_pure_set_title 'expand-prompt' '%~'

    # preform async git dirty check and fetch
    prompt_pure_async_tasks

    # Check if we should display the virtual env, we use a sufficiently high
    # index of psvar (12) here to avoid collisions with user defined entries.
    # psvar[12]=
    # Check if a conda environment is active and display it's name
    if [[ -n $CONDA_DEFAULT_ENV ]]; then
        psvar[12]="${CONDA_DEFAULT_ENV//[$'\t\r\n']}"
    fi
    # When VIRTUAL_ENV_DISABLE_PROMPT is empty, it was unset by the user and
    # Pure should take back control.
    if [[ -n $VIRTUAL_ENV ]] && [[ -z $VIRTUAL_ENV_DISABLE_PROMPT || $VIRTUAL_ENV_DISABLE_PROMPT = 12 ]]; then
        psvar[12]="${VIRTUAL_ENV:t}"
        export VIRTUAL_ENV_DISABLE_PROMPT=12
    fi

    # Make sure VIM prompt is reset.
    prompt_pure_reset_prompt_symbol

    # print the preprompt
    prompt_pure_preprompt_render "precmd"
}

# ASYNC:
################################################################################

prompt_pure_async_callback() {
    setopt localoptions noshwordsplit
    local job=$1 code=$2 output=$3 exec_time=$4 next_pending=$6
    local do_render=0

    case $job in
        \[async])
            # code is 1 for corrupted worker output and 2 for dead worker
            if [[ $code -eq 2 ]]; then
                # our worker died unexpectedly
                typeset -g prompt_pure_async_init=0
            fi
            ;;
        prompt_pure_async_vcs_info)
            typeset -gA prompt_pure_vcs_info
            local -A info

            # parse output (z) and unquote as array (Q@)
            info=("${(Q@)${(z)output}}")
            if [[ $info[pwd] != $PWD ]]; then
                # The path has changed since the check started, abort.
                return
            fi
            # check if git toplevel has changed
            if [[ $info[top] = $prompt_pure_vcs_info[top] ]]; then
                # if stored pwd is part of $PWD, $PWD is shorter and likelier
                # to be toplevel, so we update pwd
                if [[ $prompt_pure_vcs_info[pwd] = ${PWD}* ]]; then
                    prompt_pure_vcs_info[pwd]=$PWD
                fi
            else
                # store $PWD to detect if we (maybe) left the git path
                prompt_pure_vcs_info[pwd]=$PWD
            fi

            # update has a git toplevel set which means we just entered a new
            # git directory, run the async refresh tasks
            [[ -n $info[top] ]] && [[ -z $prompt_pure_vcs_info[top] ]] && prompt_pure_async_refresh

            # always update branch and toplevel
            prompt_pure_vcs_info[vcs]=$info[vcs]
            prompt_pure_vcs_info[branch]=$info[branch]
            prompt_pure_vcs_info[action]=$info[action]
            prompt_pure_vcs_info[top]=$info[top]

            prompt_pure_vcs_info[stg_top]=$info[stg_top]
            prompt_pure_vcs_info[stg_broken]=$info[stg_broken]
            prompt_pure_vcs_info[stg_stack_place]=$info[stg_stack_place]
            prompt_pure_vcs_info[stg_stack_total]=$info[stg_stack_total]

            do_render=1
            ;;
        prompt_pure_async_git_stash)
            typeset -gA prompt_pure_vcs_info

            local prev_stash=${prompt_pure_vcs_info[stash]}
            if (( code == 0 )); then
                prompt_pure_vcs_info[stash]="YES"
            else
                prompt_pure_vcs_info[stash]=
            fi
            [[ $prev_stash != ${prompt_pure_vcs_info[stash]} ]] && do_render=1
            ;;
        prompt_pure_async_git_dirty)
            typeset -gA prompt_pure_vcs_info

            local prev_dirty=${prompt_pure_vcs_info[dirty]}
            if (( code == 0 )); then
                prompt_pure_vcs_info[dirty]=
            else
                prompt_pure_vcs_info[dirty]="YES"
            fi

            [[ $prev_dirty != ${prompt_pure_vcs_info[dirty]} ]] && do_render=1

            # When prompt_pure_git_last_dirty_check_timestamp is set, the git info is displayed in a different color.
            # To distinguish between a "fresh" and a "cached" result, the preprompt is rendered before setting this
            # variable. Thus, only upon next rendering of the preprompt will the result appear in a different color.
            (( $exec_time > 5 )) && prompt_pure_git_last_dirty_check_timestamp=$EPOCHSECONDS
            ;;

        prompt_pure_async_git_arrows)
            #prompt_pure_async_git_fetch|
            typeset -gA prompt_pure_vcs_info

            # prompt_pure_async_git_fetch executes prompt_pure_async_git_arrows
            # after a successful fetch.
            case $code in
                0)
                    local REPLY
                    prompt_pure_check_git_arrows ${(ps:\t:)output}
                    if [[ ${prompt_pure_vcs_info[sync_status]} != $REPLY ]]; then
                        prompt_pure_vcs_info[sync_status]=$REPLY
                        do_render=1
                    fi
                    ;;
                99|98)
                    # Git fetch failed.
                    ;;
                *)
                    # Non-zero exit status from prompt_pure_async_git_arrows,
                    # indicating that there is no upstream configured.
                    if [[ -n ${prompt_pure_vcs_info[sync_status]} ]]; then
                        prompt_pure_vcs_info[sync_status]=
                        do_render=1
                    fi
                    ;;
            esac
            ;;
    esac

    if (( next_pending )); then
        (( do_render )) && typeset -g prompt_pure_async_render_requested=1
        return
    fi

    [[ ${prompt_pure_async_render_requested:-$do_render} = 1 ]] && prompt_pure_preprompt_render
    unset prompt_pure_async_render_requested
}

# ASYNC:TASKS
################################################################################

prompt_pure_async_tasks() {
    setopt localoptions noshwordsplit

    # initialize async worker
    ((!${prompt_pure_async_init:-0})) && {
        async_start_worker "prompt_pure" -u -n
        async_register_callback "prompt_pure" prompt_pure_async_callback
        typeset -g prompt_pure_async_init=1
    }

    # Update the current working directory of the async worker.
    async_worker_eval "prompt_pure" builtin cd -q $PWD

    typeset -gA prompt_pure_vcs_info

    if [[ $PWD != ${prompt_pure_vcs_info[pwd]}* ]]; then
        # stop any running async jobs
        async_flush_jobs "prompt_pure"

        # reset git preprompt variables, switching working tree
        prompt_pure_vcs_info[action]=
        prompt_pure_vcs_info[branch]=
        prompt_pure_vcs_info[top]=

        prompt_pure_vcs_info[stg_top]=
        prompt_pure_vcs_info[stg_broken]=
        prompt_pure_vcs_info[stg_stack_place]=
        prompt_pure_vcs_info[stg_stack_total]=

        prompt_pure_vcs_info[stash]=
        prompt_pure_vcs_info[dirty]=
        prompt_pure_vcs_info[sync_status]=

        unset prompt_pure_git_last_dirty_check_timestamp
        unset prompt_pure_git_fetch_pattern
    fi

    async_job "prompt_pure" prompt_pure_async_vcs_info

    # # only perform tasks inside git working tree
    [[ -n $prompt_pure_vcs_info[top] ]] || return

    prompt_pure_async_refresh
}

prompt_pure_async_refresh() {
    setopt localoptions noshwordsplit

    async_job "prompt_pure" prompt_pure_async_git_arrows

    # if dirty checking is sufficiently fast, tell worker to check it again, or wait for timeout
    integer time_since_last_dirty_check=$(( EPOCHSECONDS - ${prompt_pure_git_last_dirty_check_timestamp:-0} ))
    if (( time_since_last_dirty_check > $(pure_var_git_delay_dirty_check) )); then
        unset prompt_pure_git_last_dirty_check_timestamp
        # check check if there is anything to pull
        async_job "prompt_pure" prompt_pure_async_git_dirty ${PURE_GIT_UNTRACKED_DIRTY:0}
        async_job "prompt_pure" prompt_pure_async_git_stash
    fi
}


prompt_pure_async_vcs_info() {
    setopt localoptions noshwordsplit

    # configure vcs_info inside async task, this frees up vcs_info
    # to be used or configured as the user pleases.
    zstyle ':vcs_info:*' enable git svn hg
    zstyle ':vcs_info:*' use-simple true

    # only export two msg variables from vcs_info
    zstyle ':vcs_info:*' max-exports 4
    #
    # export branch (%b) and git toplevel (%R)
    zstyle ':vcs_info:*' formats '%s' '%b' '%R'
    zstyle ':vcs_info:*' actionformats '%s' '%b' '%R' "%a"

    vcs_info

    local -A info
    info[pwd]=$PWD
    info[branch]=$vcs_info_msg_1_
    info[top]=$vcs_info_msg_2_
    info[action]=$vcs_info_msg_3_
    info[vcs]=$vcs_info_msg_0_

    if (( $+commands[stg] )); then
        info[stg_top]=$(stg top)
        info[stg_stack_place]=$(stg series -A | wc -l | tr -d ' ')
        info[stg_stack_total]=$(stg series | wc -l | tr -d ' ')

        local stg_top_sha=$(stg id $(stg top))
        local git_top_sha=$(git rev-parse HEAD)

        if [[ $stg_top_sha != $git_top_sha ]]; then
            info[stg_broken]="1 : s:${stg_top_sha} : g:${git_top_sha}"
        else
            info[stg_broken]=
        fi
    fi

    print -r - ${(@kvq)info}
}

prompt_pure_async_vcs_stg_info() {
    local -A info

    if (( ! $+commands[stg] )); then
        return
    fi

    info[stg_top]=$(stg top)
    info[stg_stack_place]=$(stg series -A | wc -l | tr -d ' ')
    info[stg_stack_total]=$(stg series | wc -l | tr -d ' ')

    local stg_top_sha=$(stg id $(stg top))
    local git_top_sha=$(git rev-parse HEAD)

    if [[ $stg_top_sha != $git_top_sha ]]; then
        info[stg_broken]="1 : s:${stg_top_sha} : g:${git_top_sha}"
    else
        info[stg_broken]=
    fi

    print -r - ${(@kvq)info}
}

prompt_pure_async_git_dirty() {
    setopt localoptions noshwordsplit

    # fastest possible way to check if repo is dirty
    local untracked_dirty=$1
    if [[ $untracked_dirty = 0 ]]; then
        command git diff --no-ext-diff --quiet --exit-code
    else
        test -z "$(command git status --porcelain --ignore-submodules -unormal)"
    fi
    return $?
}

prompt_pure_async_git_stash() {
    setopt localoptions noshwordsplit

    test -f "$(git rev-parse --show-toplevel)/.git/refs/stash"
    return $?
}

prompt_pure_async_git_arrows() {
    setopt localoptions noshwordsplit

    command git rev-list --left-right --count HEAD...@'{u}'
}

# UTILS:
################################################################################

# src: https://github.com/robbyrussell/oh-my-zsh/tree/master/plugins/shrink-path
# Modified sligtly to truncate long directory names with an elipsis in the middle.
prompt_pure_shrink_path () {
    setopt localoptions noshwordsplit rc_quotes null_glob

    typeset -i lastfull=0
    typeset -i short=0
    typeset -i tilde=0
    typeset -i maxchar=0
    typeset -i named=0

    if zstyle -t ':prompt:shrink_path' fish; then
        lastfull=1
        short=1
        tilde=1
    fi
    if zstyle -t ':prompt:shrink_path' nameddirs; then
        tilde=1
        named=1
    fi
    zstyle -t ':prompt:shrink_path' last && lastfull=1
    zstyle -t ':prompt:shrink_path' short && short=1
    zstyle -t ':prompt:shrink_path' tilde && tilde=1

    zstyle -t ':prompt:shrink_path' maxchar || maxchar=15

    while [[ $1 == -* ]]; do
        case $1 in
            -f|--fish)
                lastfull=1
                short=1
                tilde=1
                ;;
            -h|--help)
                print 'Usage: shrink_path [-f -l -s -t] [directory]'
                print ' -f, --fish      fish-simulation, like -l -s -t'
                print ' -l, --last      Print the last directory''s full name'
                print ' -s, --short     Truncate directory names to the first character'
                print ' -t, --tilde     Substitute ~ for the home directory'
                print ' -T, --nameddirs Substitute named directories as well'
                print 'The long options can also be set via zstyle, like'
                print '  zstyle :prompt:shrink_path fish yes'
                return 0
                ;;
            -l|--last) lastfull=1 ;;
            -s|--short) short=1 ;;
            -t|--tilde) tilde=1 ;;
            -T|--nameddirs)
                tilde=1
                named=1
                ;;
        esac
        shift
    done

    typeset -a tree expn
    typeset result part dir=${1-$PWD}
    typeset -i i

    [[ -d $dir ]] || return 0

    if (( named )) {
        for part in ${(k)nameddirs}; {
            [[ $dir == ${nameddirs[$part]}(/*|) ]] && dir=${dir/#${nameddirs[$part]}/\~$part}
        }
    }

    (( tilde )) && dir=${dir/#$HOME/\~}
    tree=(${(s:/:)dir})
    (
        if [[ $tree[1] == \~* ]] {
            cd -q ${~tree[1]}
            result=$tree[1]
            shift tree
        } else {
            cd -q /
        }

        for dir in $tree; {
            if (( lastfull && $#tree == 1 )) {
                local rt="$tree"

                local rM=$(($#rt/2))
                local rO=0
                local rSep=""

                # Add an elipsis in the middle if the path is getting too big.
                if [[ $rM -gt $maxchar ]]; then
                    rO=$(($rM - $maxchar))
                    local rSep="|...|"
                fi

                local rtS="${rt[1,$(($rM - $rO))]}" rtE="${rt[$(($rM + 1 + $rO)),-1]}"
                result+="/$rtS$rSep$rtE"
                break
            }
            expn=(a b)
            part=''
            i=0
            until [[ (( ${#expn} == 1 )) || $dir = $expn || $i -gt 99 ]]  do
                (( i++ ))
                part+=$dir[$i]
                expn=($(echo ${part}*(-/)))
                (( short )) && break
            done
            result+="/$part"
            cd -q $dir
            shift tree
        }
        echo ${result:-/}
    )
}

# turns seconds into human readable time
# 165392 => 1d 21h 56m 32s
# https://github.com/sindresorhus/pretty-time-zsh
prompt_pure_human_time_to_var() {
    setopt localoptions noshwordsplit

    local human total_seconds=$1 var=$2
    local days=$(( total_seconds / 60 / 60 / 24 ))
    local hours=$(( total_seconds / 60 / 60 % 24 ))
    local minutes=$(( total_seconds / 60 % 60 ))
    local seconds=$(( total_seconds % 60 ))
    (( days > 0 )) && human+="${days}d "
    (( hours > 0 )) && human+="${hours}h "
    (( minutes > 0 )) && human+="${minutes}m "
    human+="${seconds}s"

    # store human readable time in variable as specified by caller
    typeset -g "${var}"="${human}"
}

# stores (into prompt_pure_cmd_exec_time) the exec time of the last command if set threshold was exceeded
prompt_pure_check_cmd_exec_time() {
    setopt localoptions noshwordsplit

    integer elapsed
    (( elapsed = EPOCHSECONDS - ${prompt_pure_cmd_timestamp:-$EPOCHSECONDS} ))
    typeset -g prompt_pure_cmd_exec_time=
    (( elapsed > $(pure_var_max_exec_time) )) && {
        prompt_pure_human_time_to_var $elapsed "prompt_pure_cmd_exec_time"
    }
}

prompt_pure_set_title() {
    setopt localoptions noshwordsplit

    # emacs terminal does not support settings the title
    (( ${+EMACS} )) && return
    case $TTY in
        # Don't set title over serial console.
        /dev/ttyS[0-9]*) return;;
    esac

    # Show hostname if connected via ssh.
    local hostname=
    if [[ -n $prompt_pure_state[username] ]]; then
        # Expand in-place in case ignore-escape is used.
        hostname="${(%):-(%m) }"
    fi

    local -a opts
    case $1 in
        expand-prompt) opts=(-P);;
        ignore-escape) opts=(-r);;
    esac

    # Set title atomically in one print statement so that it works
    # when XTRACE is enabled.
    print -n $opts $'\e]0;'${hostname}${2}$'\a'
}

# REFERENCE:
################################################################################

# Moving to ZLE Async:
#https://github.com/sorin-ionescu/prezto/blob/e07027821b1d02179f8f60c0f0fc5dafcc653ac2/modules/prompt/functions/prompt_sorin_setup


__serialize_map() {
    local var_name=$1
    eval "print -r - \${(@kvq)${var_name}}"
}

__deserialize_map() {
    local dest_var_name=$1
    local input_var_name=$2

    eval "typeset -gA ${dest_var_name}"
    eval "${dest_var_name}=( \${(z)${input_var_name}} )"
}

# Serialize/Parse Associative arrays
__reference_parse_arrays() {
    # Serialize:
    local -A info
    info[pwd]=$PWD

    local output=$(print -r - ${(@kvq)info})

    # Deserialize:
    info=("${(Q@)${(z)output}}")
}


# RUN:
################################################################################
# prompt_pure_setup "$@"
