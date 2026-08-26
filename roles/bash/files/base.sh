# Base bash configuration

# Two-argument cd, matching zsh's builtin: `cd old new` replaces the first
# occurrence of old in $PWD with new. Quoting $1 keeps glob characters literal.
cd() {
    if [ "$#" -eq 2 ]; then
        local new=${PWD/"$1"/"$2"}
        if [ "$new" = "$PWD" ]; then
            printf 'cd: string not in pwd: %s\n' "$1" >&2
            return 1
        fi
        builtin cd "$new"
    else
        builtin cd "$@"
    fi
}
