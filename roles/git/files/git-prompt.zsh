# Git branch in prompt via zsh vcs_info
autoload -Uz vcs_info
precmd_functions+=( vcs_info )
setopt prompt_subst

zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' formats ' %F{magenta}(%b)%f'
zstyle ':vcs_info:*' actionformats ' %F{magenta}(%b|%a)%f'

PROMPT='%F{green}%n@%m%f:%F{blue}%~%f${vcs_info_msg_0_}%# '
