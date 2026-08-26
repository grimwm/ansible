PLAYBOOK := ansible-playbook site.yml

# Pass -K (ask become password) automatically on Linux where tasks need sudo.
# macOS uses Homebrew for installs so become is never required.
BECOME_FLAG := $(shell [ "$$(uname -s)" = Linux ] && echo -K)

# Raw ansible-playbook arguments, forwarded verbatim.
#   make provision ARGS=-edev_machine=true
#   make provision ARGS="--tags tmux --check"
ARGS ?=

# Files scanned by `make vars` for variables documented with a `## ` comment.
VAR_SOURCES := site.yml $(wildcard roles/*/defaults/main.yml)

.PHONY: help vars tags provision provision-dev

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@printf '\nForward ansible flags with ARGS, e.g.\n'
	@printf '  make provision ARGS=-edev_machine=true\n'
	@printf '  make provision ARGS="--tags tmux --check"\n'
	@printf '  make provision-dev ARGS="--tags config"\n'
	@printf '\nRun "make vars" to list variables you can pass with -e.\n'
	@printf 'Run "make tags" to list values you can pass to --tags.\n'

vars: ## List documented variables that can be passed with -e<name>=<value>
	@printf '  %-26s %-18s %s\n' NAME DEFAULT DESCRIPTION
	@grep -hE '^[[:space:]]*#?[[:space:]]*[a-z_]+:.*##' $(VAR_SOURCES) | sort | \
		awk -F'##' '{ \
			h = $$1; d = $$2; \
			sub(/^[[:space:]]*#?[[:space:]]*/, "", h); \
			n = h; sub(/:.*/, "", n); \
			v = h; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/"/, "", v); \
			sub(/[[:space:]]+$$/, "", v); sub(/^[[:space:]]+/, "", d); \
			printf "  %-26s %-18s %s\n", n, v, d }'

tags: ## List available --tags values
	@$(PLAYBOOK) --list-tags | \
		sed -n 's/.*TASK TAGS: \[\(.*\)\]/\1/p' | \
		tr ',' '\n' | sed 's/^ *//;s/ *$$//' | sort -u | \
		awk 'NF {printf "  %s\n", $$0}'

provision: ## Provision this machine
	$(PLAYBOOK) $(BECOME_FLAG) $(ARGS)

provision-dev: ## Provision including dev tools (golang, rust, nvim, git)
	$(PLAYBOOK) $(BECOME_FLAG) -e dev_machine=true $(ARGS)
