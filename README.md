# Workstation bootstrap

Ansible playbook that provisions a workstation on **Linux**, **macOS**, or
**Windows**: shell configuration, a terminal emulator, tmux, and an optional
developer toolchain. Every role is idempotent, so re-running it is the normal way
to pick up config changes.

## Quick start

Provision the machine you're sitting at:

```bash
make provision
```

Include the developer toolchain (Go, Rust, Neovim, git config):

```bash
make provision-dev
```

`make help` lists the targets, `make vars` lists the variables you can override.
On Linux the Makefile adds `-K` automatically so Ansible prompts for your sudo
password; macOS installs everything through Homebrew and never needs it.

To pass flags straight through to `ansible-playbook`, use `ARGS`:

```bash
make provision ARGS=--check
make provision-dev ARGS="-e golang_version=1.26.0"
```

Or skip the Makefile entirely:

```bash
ansible-playbook -K site.yml -e dev_machine=true
```

## Selective runs

Every role carries a tag matching its name, so you can re-run one piece of the
playbook instead of all of it. `make tags` lists everything available.

```bash
make provision ARGS="--tags tmux"
make provision-dev ARGS="--tags golang,rust"
```

Roles are also grouped, and each role's install steps are separated from its
config deployment:

| Tag | Selects |
| --- | --- |
| `shell` | `zsh`, `bash` |
| `terminal` | `tmux`, `kitty`, `iterm2` |
| `dev` | `golang`, `rust`, `nvim`, `git`, `windows-dev` |
| `windows` | `wsl2`, `windows-dev` |
| `install` | Package installation and toolchain downloads, no config |
| `config` | Dotfile and shell drop-in deployment, no package management |

`--tags config` is the useful one day to day: it pushes edited dotfiles
(`tmux.conf`, `init.lua`, `base.zsh`, `kitty.conf`, git settings) without
touching a package manager, so it's fast and needs no sudo.

```bash
make provision-dev ARGS="--tags config"
```

Two things to know about narrowed runs:

- **`dev_machine` still applies.** `--tags golang` selects the role, but the
  role's `when` condition still has to pass, so use `make provision-dev` (or
  `-e dev_machine=true`) or nothing will run.
- **`homebrew` is tagged `always`.** It resolves the `brew` path that the macOS
  install tasks depend on, so it runs even when you narrow to another tag. On
  Linux and Windows it's a no-op. Add `--skip-tags homebrew` to opt out.

## What gets installed

Roles run in the order below. Anything gated on `dev_machine` is skipped unless
you pass `dev_machine=true` (which is what `make provision-dev` does).

| Role | `dev_machine` only | What it does |
| --- | --- | --- |
| `homebrew` | | macOS only: installs Homebrew if missing and resolves the `brew` path for later roles (Apple Silicon or Intel). |
| `zsh` | | Installs zsh on Linux. Creates `~/.zshrc.d/`, adds a sourcing loop to `~/.zshrc`, and deploys `base.zsh` (PATH additions, `ll`/`ltr` aliases, completion setup). |
| `bash` | | Creates `~/.bashrc.d/`, adds a sourcing loop to `~/.bashrc`, sources `~/.bashrc` from `~/.bash_profile` for login shells, and deploys `base.sh` (a two-argument `cd` matching zsh's builtin). |
| `golang` | yes | Installs the Go toolchain from `go.dev` into `~/.local/go`, replacing it when the installed version doesn't match `golang_version`. Adds Go to PATH via shell drop-ins (Unix) or `GOROOT` + user PATH (Windows). |
| `rust` | yes | Installs Rust via `rustup`. Deploys a zsh drop-in (Unix) or adds `~/.cargo/bin` to the user PATH (Windows). |
| `nvim` | yes | Installs Neovim — apt/dnf on Linux, Homebrew on macOS, winget on Windows — plus the tree-sitter CLI on Linux and macOS. Deploys `init.lua` to `~/.config/nvim` or `%LOCALAPPDATA%\nvim`. |
| `git` | yes | Sets global git config on Unix: identity (only if `git_user_name`/`git_user_email` are set), aliases (`st`, `ci`, `co`, `br`, `amend`, `unstage`, `last`), `init.defaultBranch=main`, merge-on-pull, colored output, and prune-on-fetch. Deploys a git-aware prompt to `~/.zshrc.d/` and `~/.bashrc.d/`. |
| `tmux` | | Installs tmux — apt/dnf on Linux, Homebrew on macOS, MSYS2 via winget on Windows — and deploys `tmux.conf`. |
| `kitty` | | Installs the kitty terminal on Linux and macOS and deploys `~/.config/kitty/kitty.conf`. |
| `iterm2` | | macOS only: installs iTerm2 via Homebrew Cask. |
| `wsl2` | | Windows only: enables the WSL and Virtual Machine Platform features (rebooting if needed), updates the WSL kernel, sets WSL 2 as the default, installs and defaults `wsl_default_distribution`, and writes `~/.wslconfig`. |
| `windows-dev` | yes | Windows only: installs dev tooling via winget (Windows Terminal, Git, VS Code, Docker Desktop, Postman, 7-Zip, Notepad++) and creates `Documents\Repositories` and `Documents\WSL`. |

Shell configuration is deployed as drop-in files rather than by editing your
rc files in place. Roles write to `~/.zshrc.d/*.zsh` and `~/.bashrc.d/*.sh`; the
`zsh` and `bash` roles add a single Ansible-managed block to `~/.zshrc` and
`~/.bashrc` that sources everything in those directories.

## Variables

Run `make vars` for the current list. All of these can be overridden with
`-e<name>=<value>` or set in inventory host/group vars.

| Variable | Default | Purpose |
| --- | --- | --- |
| `dev_machine` | `false` | Install the developer toolchain: Go, Rust, Neovim, git config, and (on Windows) `windows-dev`. |
| `git_user_name` | unset | Global git identity name. Not configured when unset. |
| `git_user_email` | unset | Global git identity email. Not configured when unset. |
| `golang_version` | `1.25.6` | Go toolchain version to install. |
| `wsl_default_distribution` | `Ubuntu` | WSL distro to install. A bare name tracks the newest stable LTS; pin (e.g. `Ubuntu-24.04`) for reproducibility. |

Larger structures — the winget package list, the created Windows directories,
the git alias list, and the `.wslconfig` resource limits — live in the
corresponding `roles/*/defaults/main.yml` and are meant to be overridden there or
via inventory vars.

## Prerequisites

Install the full `ansible` package rather than `ansible-core`, since this
playbook needs `community.general`, `ansible.windows`, and `community.windows`,
all of which the full package bundles.

```bash
# macOS
brew install ansible

# Debian/Ubuntu
sudo apt install ansible

# Fedora/RHEL
sudo dnf install ansible
```

If you're on `ansible-core` instead, install the collections explicitly:

```bash
ansible-galaxy collection install -r requirements.yml
```

Ansible can't act as a control node natively on Windows. Install WSL
(`wsl --install`), then install Ansible inside it using the Linux instructions
above.

On Windows targets, `winget` must already be present — it ships with the App
Installer on current Windows 10 and 11.

## Targeting other hosts

`inventory/localhost.yml` defines only `localhost` with `ansible_connection:
local`, so out of the box this provisions the machine running the playbook. To
provision a remote or Windows host, add it to the inventory with the appropriate
connection variables; `site.yml` targets `all` and branches on
`ansible_facts['os_family']`, so the same playbook applies.

## Layout

```
site.yml            Playbook: role order and dev_machine gating
ansible.cfg         inventory/, roles/, collections/ paths
Makefile            provision / provision-dev / vars entry points
requirements.yml    Galaxy collections (only needed on ansible-core)
inventory/          localhost, local connection
roles/<name>/
  tasks/main.yml    Imports install.yml and/or config.yml, applying those tags
  tasks/install*.yml  Per-OS install steps
  tasks/config*.yml   Per-OS config deployment
  files/            Config deployed verbatim (tmux.conf, init.lua, base.zsh, ...)
  defaults/         Overridable variables
```

Roles split OS-specific work into separate `install_linux.yml` /
`install_macos.yml` / `install_windows.yml` files pulled in with `include_tasks`
and an `ansible_facts` condition. Because inclusion is dynamic, a Linux run never
parses the Windows tasks, so it won't fail on the Windows collections being
absent.

Per-role tags are declared in `site.yml`; the `install` and `config` tags are
applied in each role's `tasks/main.yml` at the import. `wsl2` is the one role
without that split, since enabling the Windows features and writing
`.wslconfig` live in the same task file.
