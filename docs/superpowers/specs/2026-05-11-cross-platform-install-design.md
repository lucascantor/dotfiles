# Cross-Platform `install.sh` Design

**Status:** Approved (2026-05-11)
**Scope:** Rewrite `install.sh` to support macOS and Debian/Ubuntu Linux from a single script, prefer Homebrew everywhere it has a formula, retroactively migrate manual installs on the maintainer's Mac to Homebrew, and add a dry-run + interactive-plan UX with idempotent re-runs.

## 1. Goals

- **Cross-platform:** one `install.sh` runs on macOS (Apple Silicon and Intel) and Debian/Ubuntu Linux.
- **Homebrew-first:** Homebrew is the canonical package manager on both OSes; the script installs Homebrew if absent.
- **Retroactive migration:** the maintainer's Mac currently has manual `git clone` installs of `tfenv` and `spaceship-prompt`, plus stale plain-file copies of dotfiles in `$HOME`. The script must replace these with Homebrew-managed installs and symlinks when the user opts in.
- **Dry-run + interactive plan:** every run prints a planned-actions list before doing anything. `--dry-run` previews and exits. `--yes` skips the confirmation prompt. `--migrate` enables destructive replacement of legacy state.
- **Idempotent:** state is detected from filesystem and `brew` reality, not from marker files. Re-runs converge.

## 2. Non-goals

- Other Linux distributions (RHEL, Arch, Alpine). Linux support is Debian/Ubuntu only — apt is the bootstrap package manager.
- Other shells (fish, nu). Zsh + Oh My Zsh + Spaceship stays the target.
- Container/CI installs. The script targets interactive developer machines.
- Migrating commit history, GPG signing, or user identity from existing `~/.gitconfig` — that file stays untouched aside from one `[include]` line append.

## 3. Architecture

Single shell script, ~300 lines, with three layers:

```
install.sh
├── helpers       (os detect, log_action, planned_action, prompt_or_proceed)
├── plan_*        pure functions that decide and append to a planned_actions array
├── do_*          execution functions that match plan_* names
└── main          detect OS → run all plan_* → render plan → prompt → run all do_*
```

**OS dispatch** is via `uname -s`:
- `Darwin` → macOS code paths (Homebrew at `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel).
- `Linux` → Linux code paths (Linuxbrew at `/home/linuxbrew/.linuxbrew`, with `apt-get` used only for the Linuxbrew bootstrap prerequisites and the system `zsh`).
- Anything else → exit non-zero with an "unsupported OS" message.

**Planning vs execution.** Every action is decided by a pure `plan_*` function that appends a `(do_name, description, status)` tuple to a `planned_actions` array. Execution iterates the array and invokes the matching `do_*` function. `--dry-run` skips the execution phase entirely. This separation is what makes the interactive plan honest: the plan output is exactly what will run.

## 4. Package mapping

| Item | macOS | Linux | Notes |
|---|---|---|---|
| Homebrew | curl-install if absent (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`) | same | prerequisite for everything below |
| zsh | system zsh; `brew install zsh` only if missing | `sudo apt-get install zsh` | needs `/etc/shells` registration so `chsh` works — apt's zsh handles that; brew's does not |
| oh-my-zsh | official curl install with `RUNZSH=no CHSH=no ... --unattended` | same | no Homebrew formula exists; this stays curl-based |
| spaceship-prompt | `brew install spaceship` | `brew install spaceship` | replaces the manual git clone |
| tfenv | `brew install tfenv` | `brew install tfenv` | replaces the manual git clone; the `export PATH="$HOME/.tfenv/bin:$PATH"` line is removed from the repo's `.zshrc` since brew puts the binary on `PATH` already |
| Maple Mono NF | `brew install --cask font-maple-mono-nf` | download latest `MapleMono-NF-unhinted.zip` (or equivalent NF asset) from `github.com/subframe7536/maple-font` releases, extract to `~/.local/share/fonts/MapleMono-NF/`, run `fc-cache -fv` | replaces `powerline` / `fonts-powerline` from the original script — casks don't exist on Linuxbrew |
| Linux bootstrap deps | n/a | `sudo apt-get install -y curl git build-essential procps file` | only what Linuxbrew's installer needs to bootstrap |

## 5. CLI surface

```
./install.sh [--dry-run] [--yes] [--migrate] [--help]
```

- `--dry-run` — print plan, exit 0. Overrides `--yes` if both passed.
- `--yes` — skip the "Proceed? [y/N]" prompt.
- `--migrate` — enable destructive replacement of pre-existing manual installs and stale-file backups (see §6).
- `--help` — print usage and exit.

Flags are independent and combinable. Unknown flags exit non-zero.

## 6. Migration semantics (`--migrate`)

Default behavior is conservative. When the script finds pre-existing state that conflicts with its intended action, it **warns and skips** rather than touching anything. `--migrate` opts into destructive replacement.

| Pre-existing state | Default behavior | `--migrate` behavior |
|---|---|---|
| `~/.tfenv/` is a git clone | Warn "manual tfenv install detected, skipping `brew install tfenv` — re-run with `--migrate` to replace". Mark step as `[skip: manual install present]`. | `rm -rf ~/.tfenv`, then `brew install tfenv`. |
| `~/.oh-my-zsh/custom/themes/spaceship-prompt/` is a git clone | Same shape of warn-and-skip. | `rm -rf` that directory, then `brew install spaceship`. |
| `~/.zshrc` is a regular file with content **byte-identical** to the repo's | Replace with symlink (safe; no data loss). | Same. |
| `~/.zshrc` is a regular file with content **differing** from the repo's | Warn "local edits detected, skipping symlink — re-run with `--migrate` to back up and replace". | Back up to `~/.zshrc.bak.YYYYMMDD-HHMMSS`, then symlink. |
| `~/.zshrc` already a symlink to the repo | No-op. | No-op. |
| `~/.zshrc` is a symlink pointing elsewhere | Warn and skip. | Note current target in plan output, replace symlink. |

The same matrix applies to `.aliases`, `.functions`, `.gitignore`.

## 7. Repo content sync from Mac

This precedes the install.sh rewrite as part of the same PR. Source of truth is the maintainer's current Mac state.

- **`.gitconfig`**: copy the working-tree contents of `~/repos/dotfiles/.gitconfig` (branch `noir`, uncommitted edits as of 2026-05-11) into the worktree. That captures the section reorganization and the additions of `[pull] rebase = true` and `[init] defaultBranch = main`.
- **`.zshrc`**: add a trailing newline (file currently lacks one). No other content changes — the maintainer's 3 personal extras (Secretive `SSH_AUTH_SOCK`, `~/.local/bin` PATH) do **not** go into the committed repo. They are written to `~/.extra` on the maintainer's Mac during install (see §8).
- **`.aliases`, `.functions`, `.gitignore`**: no changes (Mac copies are byte-identical to the repo).

## 8. `~/.extra` handling

The repo's `.zshrc` already sources `~/.extra` if present (it's the established slot for "settings you don't want to commit"). The script's plan includes one extra action on the maintainer's Mac during the first `--migrate` run:

- If `~/.extra` does not exist: write the following (1 comment + 2 export directives):
  ```
  # Secretive Agent
  export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
  export PATH="$HOME/.local/bin:$PATH"
  ```
  (Note: `$HOME` is used rather than the hard-coded `/Users/lucas` path that currently appears in the maintainer's `~/.zshrc`. This is intentional — `~/.extra` should be portable across the maintainer's machines.)
- If `~/.extra` exists: never touch it. Mark the step as `[skip: ~/.extra already exists]`.

This step is in the plan for *every* run on macOS, but is a no-op when the file exists. It is **not** gated behind `--migrate` because writing a new file is non-destructive.

## 9. `.zshrc` and shell environment

The repo's `.zshrc` changes:

1. Remove the `export PATH="$HOME/.tfenv/bin:$PATH"` line (now redundant — brew installs tfenv to a directory already on `PATH`).
2. Add a trailing newline.

The script does **not** add brew's `shellenv` line to the repo's `.zshrc`, because the prefix differs by machine (`/opt/homebrew`, `/usr/local`, `/home/linuxbrew/.linuxbrew`) and would have to live in machine-local config anyway. Instead:

- **macOS:** Homebrew's installer adds `/opt/homebrew/bin` (or `/usr/local/bin`) to system `PATH` via `/etc/paths.d/`, so no per-user shell init is required. No action needed from the script.
- **Linux:** Homebrew's installer writes a shellenv line to `~/.profile`, which zsh does not source. The script ensures `eval "$($BREW_PREFIX/bin/brew shellenv)"` is present in `~/.zprofile` (creating that file if absent). Detection: `grep -q 'brew shellenv' ~/.zprofile`.

This keeps the repo's `.zshrc` portable across machines while ensuring brew binaries are on `PATH` for new zsh login sessions.

## 10. `.gitconfig` integration

Unchanged from the existing approach: the script appends one `include.path` line to `~/.gitconfig` pointing at the repo's `.gitconfig`. Identity (`[user]`), signing keys, and any other config in `~/.gitconfig` are preserved.

Idempotency: `git config --global --get-all include.path | grep -qxF <repo>/.gitconfig` detects a prior install. The line is added only if missing.

## 11. Idempotency model

Every step computes its state from observable facts (filesystem + `brew` + `git config`), not from a marker file. Detection rules:

| Step | "Already done" detection |
|---|---|
| Homebrew install | `command -v brew` succeeds AND its prefix is one of the canonical locations |
| Brew formula installed | `brew list --formula <name> >/dev/null 2>&1` |
| Brew cask installed (macOS) | `brew list --cask <name> >/dev/null 2>&1` |
| Maple Mono on Linux | `fc-list \| grep -qi 'Maple Mono NF'` |
| Oh My Zsh | `-d ~/.oh-my-zsh` |
| Spaceship theme symlink | `readlink ~/.oh-my-zsh/custom/themes/spaceship.zsh-theme` starts with `$(brew --prefix)/opt/spaceship/` |
| tfenv manual install present (triggers `--migrate` warning) | `-d ~/.tfenv/.git` |
| spaceship manual install present | `-d ~/.oh-my-zsh/custom/themes/spaceship-prompt` |
| Dotfile symlink correct | `readlink ~/.zshrc` equals `<repo>/.zshrc` |
| Dotfile regular file identical to repo | `cmp -s <repo>/.zshrc ~/.zshrc` |
| `~/.gitconfig` include present | `git config --global --get-all include.path \| grep -qxF <repo>/.gitconfig` |
| `~/.extra` migration | `-f ~/.extra` (never overwrite) |
| Linux brew shellenv in `~/.zprofile` | `grep -q 'brew shellenv' ~/.zprofile` (file may be absent — treated as not-done) |

## 12. Plan output format

Example output on the maintainer's Mac, first run with `--migrate`:

```
$ ./install.sh --migrate

Planned actions for darwin (arm64) — Homebrew already installed:

  Packages
    1. brew install zsh                              [skip: already present]
    2. brew install spaceship                        [migrate: remove ~/.oh-my-zsh/custom/themes/spaceship-prompt git clone first]
    3. brew install tfenv                            [migrate: remove ~/.tfenv git clone first]
    4. brew install --cask font-maple-mono-nf

  Symlinks
    5. ln -sfn <repo>/.zshrc      ~/.zshrc           [convert: regular file, identical content]
    6. ln -sfn <repo>/.aliases    ~/.aliases         [convert: regular file, identical content]
    7. ln -sfn <repo>/.functions  ~/.functions      [convert: regular file, identical content]
    8. ln -sfn <repo>/.gitignore  ~/.gitignore       [convert: regular file, identical content]
    9. ln -sfn $(brew --prefix)/opt/spaceship/spaceship.zsh-theme  ~/.oh-my-zsh/custom/themes/spaceship.zsh-theme

  Config
   10. git config --global --add include.path <repo>/.gitconfig
   11. Write ~/.extra with SSH_AUTH_SOCK + PATH=~/.local/bin   [new file, will not overwrite if present]

  Curl installs (no brew formula available)
   12. Install Oh My Zsh                              [skip: ~/.oh-my-zsh already present]

Proceed? [y/N]
```

Conventions:
- Each line shows the action plus a bracketed `[status]` annotation.
- Status vocabulary: `skip`, `migrate`, `convert`, `new`, `backup`, `replace`, no-annotation for plain pending actions.
- Idempotent re-runs naturally produce mostly `[skip: already present]` lines.
- Stderr is reserved for errors; stdout has plan + progress + prompt.
- The plan is printed once. During execution (after the prompt), each action prints a single status line as it runs.

## 13. Error handling

- `set -euo pipefail` throughout.
- Each `plan_*` function is non-fatal (it observes state and decides; never errors out).
- Each `do_*` function may fail, in which case the script exits non-zero with which step failed and what command produced the error.
- No transactional rollback. Re-running converges via the detection rules.
- On Linux, sudo prompts are surfaced in the plan ("Will run: sudo apt-get install ...") so the user isn't surprised mid-execution.

## 14. README updates

- New **Requirements** section listing macOS (any recent version, Apple Silicon or Intel) or Debian/Ubuntu.
- Update the **Install** section to mention `--dry-run`, `--yes`, `--migrate` flags, with one-line descriptions.
- Update the "It installs..." list:
  - drop `powerline`, `fonts-powerline`
  - add `Homebrew` (bootstrap), `Maple Mono NF`
  - mention that `tfenv` and `spaceship-prompt` are now installed via Homebrew on both OSes
- Preserve the existing notes on `.bashrc` zsh-handoff trampoline and `.gitconfig` `[include]` behavior.

## 15. Test plan (verification)

Tested manually on the maintainer's Mac after implementation:

1. **Default re-run (no flags)** — expect plan to show warnings for `~/.tfenv` and `spaceship-prompt` manual installs (`[skip: manual install present]`), and convert dotfiles to symlinks since content is identical. Confirm at the prompt. Verify post-run state.
2. **`--dry-run`** — expect identical plan output, no changes, exit 0.
3. **`--migrate`** — expect the migrate-annotated actions to be planned. Confirm. Verify `~/.tfenv` and spaceship git clone removed, brew formulas present, symlinks correct, `.zshrc` no longer contains the tfenv PATH line.
4. **Second run** — expect plan to show mostly `[skip: already present]` lines. Confirm. Verify no changes.
5. **Linux smoke test** in a fresh Ubuntu container (one-off, not committed):
   - `docker run -it ubuntu:24.04 bash` → clone repo → `./install.sh --dry-run` → verify plan looks correct
   - Then `./install.sh --yes` and verify exit 0
   - Optional: verify font shows up in `fc-list`

## 16. Out of scope (deferred)

- Automatic `chsh -s zsh` — kept as a printed hint in the post-install message, as in the current script.
- Removing the maintainer's hardcoded SSH agent path from `~/.zshrc` on the Mac — this happens organically when the symlink replaces the regular file (the new `.zshrc` won't have those lines, and `~/.extra` picks them up via the existing source loop).
- Auto-detection of additional `.extra` content beyond the SSH agent + local bin path.
- Switching the maintainer's terminal font to Maple Mono NF — install only; terminal config is the user's responsibility.
