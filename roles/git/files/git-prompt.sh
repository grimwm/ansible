# Git branch in prompt for bash
__git_branch() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    printf ' \033[35m(%s)\033[0m' "$branch"
}

PS1='\[\033[32m\]\u@\h\[\033[0m\]:\[\033[34m\]\w\[\033[0m\]$(__git_branch)\$ '
