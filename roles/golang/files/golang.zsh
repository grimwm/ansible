# Go environment. GOROOT is deliberately NOT set: a modern go binary locates
# its own root, and a pinned GOROOT outlives the install it points at -- a
# stale ~/.local/go GOROOT (1.25.6) corrupted every build the day a repo's
# go.mod moved to 1.26, with "compile: version X does not match go tool
# version Y" errors. On macOS the toolchain comes from Homebrew; on Linux
# the role's tarball install lives in ~/.local/go, whose bin dir is added
# here (a nonexistent entry is harmless on macOS, where that install is
# removed).
export PATH="$HOME/.local/go/bin:$HOME/go/bin:$PATH"
