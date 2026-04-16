PLAYBOOK := ansible-playbook site.yml

# Pass -K (ask become password) automatically on Linux where tasks need sudo.
# macOS uses Homebrew for installs so become is never required.
BECOME_FLAG := $(shell [ "$$(uname -s)" = Linux ] && echo -K)

.PHONY: help dev base

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

dev: ## Provision with dev tools (golang, rust, nvim, git)
	$(PLAYBOOK) -e dev_machine=true $(BECOME_FLAG)

base: ## Provision without dev tools
	$(PLAYBOOK) $(BECOME_FLAG)
