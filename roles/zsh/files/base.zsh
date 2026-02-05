export PATH="$HOME/.local/bin:$PATH"
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"

alias ll='ls -l'
alias ltr='ls -ltr'

# Use bash-style word handling (word boundaries at punctuation)
autoload -U select-word-style
select-word-style bash

# Enable completion system (for subcommands, options, etc.)
autoload -Uz compinit
compinit

# Auto-rehash to find new executables
zstyle ':completion:*' rehash true
