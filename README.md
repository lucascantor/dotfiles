# dotfiles

Shell defaults.

## Requirements

- macOS (Apple Silicon or Intel) or Debian/Ubuntu Linux
- `sudo` on Linux (used only for `apt-get install` of bootstrap dependencies + zsh)

## Install

```bash
git clone https://codeberg.org/lucascantor/dotfiles.git ~/repos/dotfiles
cd ~/repos/dotfiles
./install.sh --dry-run    # preview the plan
./install.sh              # run it (prompts before making changes)
```

### Flags

- `--dry-run` — print the planned actions and exit without making changes
- `--yes` — skip the "Proceed? [y/N]" confirmation prompt
- `--migrate` — replace pre-existing manual installs (e.g. `~/.tfenv` git clone → Homebrew tfenv) and back up + replace stale plain-file copies of dotfiles in `$HOME`

`install.sh` is idempotent — re-run it after pulling updates to pick them up. It:

- bootstraps **Homebrew** if absent (and Linux build deps via `apt-get`)
- installs **zsh** (via apt on Linux; uses system zsh on macOS), **Oh My Zsh** (official curl install — no Homebrew formula), **Spaceship prompt** (`brew install spaceship`), **tfenv** (`brew install tfenv`), and the **Maple Mono NF** font (Homebrew cask on macOS; GitHub release on Linux)
- symlinks `.zshrc`, `.aliases`, `.functions`, and `.gitignore` from this repo into `$HOME`
- layers this repo's `.gitconfig` into `~/.gitconfig` via git's `[include]` directive, so any existing identity or signing config is preserved
- skips `.bashrc` so any local PATH additions there are preserved (the repo's `.bashrc` is a safe zsh-handoff trampoline you can opt into manually if `chsh` is unavailable)

Once it finishes, change your login shell to zsh:

```bash
chsh -s "$(command -v zsh)"
```

### Machine-specific config

For PATH additions or other settings that shouldn't live in this repo, drop them in:

- `~/.path` — `PATH` additions
- `~/.extra` — anything else you don't want to commit

Both are sourced by `.zshrc` if present.

## Contributing Workflow

See this repo's contributing workflow [here](./CONTRIBUTING.md).

## License

See this repo's license [here](./LICENSE).
