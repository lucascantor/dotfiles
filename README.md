# dotfiles

Shell defaults.

## Install

```bash
git clone https://codeberg.org/lucascantor/dotfiles.git ~/repos/dotfiles
cd ~/repos/dotfiles
./install.sh
```

`install.sh` is idempotent — re-run it after pulling updates to pick them up. It:

- installs `zsh`, `powerline`, `fonts-powerline`, `oh-my-zsh`, `spaceship-prompt`, and `tfenv` if they are missing
- symlinks `.zshrc`, `.aliases`, `.functions`, and `.gitignore` into `$HOME`
- layers this repo's `.gitconfig` into `~/.gitconfig` via git's `[include]` directive, so any existing identity or signing config is preserved
- skips `.bashrc` so any local PATH additions there are preserved (the repo's `.bashrc` is a safe zsh-handoff trampoline you can opt into manually if `chsh` is unavailable)

Once it finishes, change your login shell to zsh:

```bash
chsh -s "$(command -v zsh)"
```

For machine-specific PATH additions that shouldn't live in this repo, drop them in `~/.path` — `.zshrc` will source it on shell start.

## Contributing Workflow

See this repo's contributing workflow [here](./CONTRIBUTING.md).

## License

See this repo's license [here](./LICENSE).
