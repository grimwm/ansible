## What this repo does

This is a small Ansible repo for bootstrapping a machine with **tmux** and installing your `tmux.conf`.

- **Linux**: installs `tmux` via the native package manager (apt/dnf/etc) and writes `~/.tmux.conf`
- **macOS**: installs Homebrew (if missing), installs `tmux` via brew, writes `~/.tmux.conf`
- **Windows**: installs MSYS2 via winget, installs `tmux` inside MSYS2, writes:
  - `%USERPROFILE%\.tmux.conf`
  - `C:\msys64\home\<username>\.tmux.conf` (if that directory exists)

## Prerequisites

### macOS

Install Ansible via Homebrew:

```bash
brew install ansible
```

### Linux

Install Ansible via your package manager:

```bash
# Debian/Ubuntu
sudo apt install ansible

# Fedora/RHEL
sudo dnf install ansible
```

### Windows

Ansible cannot run natively on Windows as a control node. Use WSL (Windows Subsystem for Linux):

```powershell
wsl --install
```

Then inside WSL, install Ansible using the Linux instructions above.

## Quick start (localhost)

### Linux-only (localhost)

If you're only running this on Linux, you **do not** need any extra collections.

```bash
ansible-playbook -K site.yml
```

### macOS and/or Windows targets

If you're going to run this against macOS and/or Windows hosts, install the required collections first:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -K site.yml
```

## Notes

- On **Windows**, `winget` must already be available (Windows 10/11 with App Installer).
- The Windows approach uses **MSYS2** because tmux is not reliably available as a native winget package.
- This repo uses `include_tasks` for OS-specific installs so your Linux runs won't error just because Windows/macOS collections aren't installed.
