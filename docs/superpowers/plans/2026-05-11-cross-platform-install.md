# Cross-Platform `install.sh` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `install.sh` to support macOS and Debian/Ubuntu from a single script, prefer Homebrew, gain `--dry-run`/`--yes`/`--migrate` flags, and retroactively migrate the maintainer's Mac off manual git-clone installs.

**Architecture:** Single bash script (~300 lines) split into pure `plan_*` planning functions and matching `do_*` execution functions, with OS dispatch via `uname -s`. Plan-then-prompt UX prints every action before running it; `--dry-run` exits after printing; idempotency is detected from filesystem/brew state rather than marker files.

**Tech Stack:** Bash (`set -euo pipefail`), `shellcheck` for static analysis, Homebrew (on both OSes), apt (Linux bootstrap only), `git`, `curl`, `fc-cache` (Linux fonts).

**Spec:** [`docs/superpowers/specs/2026-05-11-cross-platform-install-design.md`](../specs/2026-05-11-cross-platform-install-design.md)

---

## Pre-flight

Before starting Task 1, confirm the implementer has:
- Access to the maintainer's Mac (`/Users/lucas/...` paths referenced below)
- `~/repos/dotfiles` exists with uncommitted `.gitconfig` edits on branch `noir` (the source of truth for the gitconfig content sync — verify with `git -C ~/repos/dotfiles status` and `git -C ~/repos/dotfiles branch --show-current`)
- `shellcheck` available (`brew install shellcheck` if missing — this is the only test dependency)
- Working directory is the worktree at `/Users/lucas/Repos/dotfiles/.claude/worktrees/modest-poitras-96e985`

If `shellcheck` is missing, install it first: `brew install shellcheck`.

---

## Phase A — Repo content sync (small, foundational commits)

### Task 1: Sync `.gitconfig` from maintainer's Mac working tree

**Files:**
- Modify: `.gitconfig`

The maintainer has uncommitted edits to `~/repos/dotfiles/.gitconfig` on branch `noir` (added `[pull] rebase = true` and `[init] defaultBranch = main`; removed `[commit] gpgsign = true` and `[init] templateDir`; reorganized section order with `# --------------------` headers). These edits become the new repo state.

- [ ] **Step 1: Diff to confirm content differs**

Run: `diff -u .gitconfig ~/repos/dotfiles/.gitconfig`
Expected: shows the reorganization + the `[pull] rebase = true` / `[init] defaultBranch = main` additions / `[commit] gpgsign` removal — confirms there are real changes to import.

- [ ] **Step 2: Copy working-tree `.gitconfig` from primary clone into worktree**

Run: `cp ~/repos/dotfiles/.gitconfig .gitconfig`

- [ ] **Step 3: Verify the copy landed**

Run: `diff -u .gitconfig ~/repos/dotfiles/.gitconfig`
Expected: no output (files now identical).

- [ ] **Step 4: Spot-check the section ordering**

Run: `grep -n '^\[' .gitconfig | head -20`
Expected: first sections are `[push]`, `[pull]`, `[init]`, `[apply]`, `[diff]`, `[merge]`, `[help]`, `[core]`, `[alias]` (the new ordering from `noir`).

- [ ] **Step 5: Commit**

```bash
git add .gitconfig
git commit -m "sync .gitconfig with maintainer's local edits

Pulls in the section reorg and the additions of [pull] rebase = true and
[init] defaultBranch = main that were sitting uncommitted on the maintainer's
primary clone. Removes the prior [commit] gpgsign = true and [init]
templateDir lines (those belong in ~/.gitconfig, not the shared repo)."
```

### Task 2: Sync `.zshrc` (trailing newline + remove tfenv PATH line)

**Files:**
- Modify: `.zshrc`

Two changes: (1) add a trailing newline (current file is missing one), (2) remove the `export PATH="$HOME/.tfenv/bin:$PATH"` line — the new install.sh installs tfenv via brew, which puts the binary on PATH already.

- [ ] **Step 1: Confirm the trailing newline is missing and the tfenv line is present**

Run: `tail -c 1 .zshrc | xxd; echo; grep -n 'tfenv' .zshrc`
Expected: last byte is something other than `0a` (newline); grep finds the tfenv export line.

- [ ] **Step 2: Edit `.zshrc` — remove the tfenv block and ensure file ends with newline**

Delete lines 31-32 (the comment `# Add ~/.tfenv/bin to $PATH` and the `export PATH="$HOME/.tfenv/bin:$PATH"` line). Also delete the blank line before it (currently line 30) if removing those two lines would leave a trailing blank. Ensure the file ends with `\n`.

The resulting `.zshrc` should end with the line:

```
command -v terraform > /dev/null && complete -o nospace -C terraform terraform
```

followed by a single newline.

- [ ] **Step 3: Verify**

Run: `tail -c 1 .zshrc | xxd; grep -c 'tfenv' .zshrc`
Expected: last byte is `0a` (`0000000: 0a  .`); grep returns `0` (no matches).

- [ ] **Step 4: Commit**

```bash
git add .zshrc
git commit -m "remove tfenv PATH export from .zshrc

The new install.sh installs tfenv via Homebrew, which places the binary on
PATH already through brew's prefix. The manual ~/.tfenv/bin export is
redundant once we're brew-managed. Also adds a trailing newline."
```

---

## Phase B — Implementation of new `install.sh`

The new script is developed incrementally with commits at meaningful checkpoints. Each task adds a working slice; `--dry-run` is the running test surface.

### Task 3: Scaffold the new `install.sh` — arg parsing, OS detection, helpers, plan/execute split

**Files:**
- Modify: `install.sh` (full rewrite)

This task replaces the current 75-line script with a 100-line scaffolding that parses flags, detects OS, sets up the planning data structures, and runs the plan/execute split with no actions registered yet. Subsequent tasks plug in the `plan_*`/`do_*` pairs.

- [ ] **Step 1: Write the new `install.sh` scaffolding**

Replace the entire contents of `install.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR="$SCRIPT_DIR"

# -------- Flags --------
DRY_RUN=0
ASSUME_YES=0
MIGRATE=0

usage() {
	cat <<'EOF'
Usage: ./install.sh [--dry-run] [--yes] [--migrate] [--help]

  --dry-run   Print the planned actions and exit without making changes.
  --yes       Skip the "Proceed? [y/N]" confirmation prompt.
  --migrate   Enable destructive replacement of pre-existing manual installs
              (e.g. ~/.tfenv git clone -> brew tfenv) and back up + replace
              stale plain-file copies of dotfiles in $HOME.
  --help      Print this message and exit.

Flags are independent and can be combined. --dry-run overrides --yes.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--yes)     ASSUME_YES=1 ;;
		--migrate) MIGRATE=1 ;;
		--help|-h) usage; exit 0 ;;
		*) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

# -------- OS detection --------
OS=""
case "$(uname -s)" in
	Darwin) OS="macos" ;;
	Linux)  OS="linux" ;;
	*) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

ARCH=$(uname -m)

# -------- Planned actions --------
# Each entry: "section|do_function|description|status"
# section ∈ {Packages, Symlinks, Config, "Curl installs (no brew formula available)"}
# status ∈ {"", "skip: ...", "migrate: ...", "convert: ...", "new", "backup ...", "replace ..."}
PLANNED_ACTIONS=()

planned_action() {
	# Args: section, do_function, description, [status]
	local section="$1" fn="$2" desc="$3" status="${4:-}"
	PLANNED_ACTIONS+=("$section|$fn|$desc|$status")
}

render_plan() {
	local prev_section=""
	local i=0
	echo
	echo "Planned actions for $OS ($ARCH):"
	echo
	for entry in "${PLANNED_ACTIONS[@]}"; do
		local section="${entry%%|*}"
		local rest="${entry#*|}"
		local fn="${rest%%|*}"
		rest="${rest#*|}"
		local desc="${rest%%|*}"
		local status="${rest#*|}"
		if [ "$section" != "$prev_section" ]; then
			echo "  $section"
			prev_section="$section"
		fi
		i=$((i+1))
		if [ -n "$status" ]; then
			printf "   %2d. %s   [%s]\n" "$i" "$desc" "$status"
		else
			printf "   %2d. %s\n" "$i" "$desc"
		fi
	done
	echo
}

execute_plan() {
	for entry in "${PLANNED_ACTIONS[@]}"; do
		local rest="${entry#*|}"
		local fn="${rest%%|*}"
		rest="${rest#*|}"
		local desc="${rest%%|*}"
		local status="${rest#*|}"
		# Skips are no-ops at execute time. The fn is still called but is
		# expected to short-circuit when its detection says "already done".
		echo "→ $desc"
		"$fn"
	done
}

prompt_or_proceed() {
	if [ "$ASSUME_YES" -eq 1 ]; then
		return 0
	fi
	read -r -p "Proceed? [y/N] " reply
	case "$reply" in
		[yY]|[yY][eE][sS]) return 0 ;;
		*) echo "Aborted."; exit 0 ;;
	esac
}

# -------- Plan registration (filled in by subsequent tasks) --------

register_plan() {
	: # Tasks 4-10 plug in plan_* calls here.
}

# -------- Main --------

main() {
	register_plan
	render_plan
	if [ "$DRY_RUN" -eq 1 ]; then
		exit 0
	fi
	if [ "${#PLANNED_ACTIONS[@]}" -eq 0 ]; then
		echo "Nothing to do."
		exit 0
	fi
	prompt_or_proceed
	execute_plan
	echo
	echo "Done."
}

main "$@"
```

- [ ] **Step 2: Static check with shellcheck**

Run: `shellcheck install.sh`
Expected: no errors. (Warnings about unused variables `MIGRATE`, `REPO_DIR`, etc. are acceptable — they're consumed in later tasks. If shellcheck flags them as errors, add `# shellcheck disable=SC2034` on the line.)

- [ ] **Step 3: Syntax check**

Run: `bash -n install.sh`
Expected: no output (clean parse).

- [ ] **Step 4: Smoke-test `--help`**

Run: `./install.sh --help`
Expected: prints the usage block, exits 0.

- [ ] **Step 5: Smoke-test `--dry-run`**

Run: `./install.sh --dry-run`
Expected output:
```
Planned actions for macos (arm64):

```
followed by an empty plan body and exit 0. (No actions registered yet — empty plan is correct.)

- [ ] **Step 6: Smoke-test unknown flag**

Run: `./install.sh --bogus`
Expected: prints `Unknown flag: --bogus` to stderr, prints usage to stderr, exits 2.

- [ ] **Step 7: Commit**

```bash
git add install.sh
git commit -m "scaffold rewrite of install.sh with plan/execute split

Sets up argument parsing (--dry-run, --yes, --migrate, --help), OS detection
via uname -s, a planned_actions array with section grouping, render_plan,
execute_plan, and prompt_or_proceed. No actions registered yet — subsequent
commits plug in plan_* / do_* pairs."
```

### Task 4: Add Homebrew bootstrap

**Files:**
- Modify: `install.sh`

Adds the Homebrew installation step. On both OSes, runs the official curl-pipe install if `brew` is not on PATH. On Linux, this requires apt prerequisites (curl, git, build-essential, procps, file) — those are handled in Task 12.

- [ ] **Step 1: Add `plan_homebrew` and `do_homebrew` to `install.sh`**

Insert these functions immediately above the `register_plan` function:

```bash
# -------- Homebrew --------

BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

brew_prefix() {
	# Best-guess brew prefix for the current OS/arch. Used in plan text;
	# do_* functions re-resolve via `brew --prefix` after install.
	if command -v brew > /dev/null 2>&1; then
		brew --prefix
		return
	fi
	case "$OS" in
		macos)
			if [ "$ARCH" = "arm64" ]; then
				echo "/opt/homebrew"
			else
				echo "/usr/local"
			fi
			;;
		linux) echo "/home/linuxbrew/.linuxbrew" ;;
	esac
}

plan_homebrew() {
	if command -v brew > /dev/null 2>&1; then
		planned_action "Packages" "do_homebrew" "Install Homebrew" "skip: already present at $(brew --prefix)"
	else
		planned_action "Packages" "do_homebrew" "Install Homebrew (curl-install from $BREW_INSTALL_URL)"
	fi
}

do_homebrew() {
	if command -v brew > /dev/null 2>&1; then
		return 0
	fi
	NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$BREW_INSTALL_URL")"
	# After install, expose brew in this shell so subsequent steps can use it.
	local prefix
	prefix=$(brew_prefix)
	if [ -x "$prefix/bin/brew" ]; then
		eval "$("$prefix/bin/brew" shellenv)"
	fi
}
```

- [ ] **Step 2: Wire `plan_homebrew` into `register_plan`**

Replace the body of `register_plan` (the `:` placeholder) with:

```bash
	plan_homebrew
```

- [ ] **Step 3: Static check + dry-run**

```bash
shellcheck install.sh
bash -n install.sh
./install.sh --dry-run
```

Expected `--dry-run` output (on a Mac with Homebrew already installed):
```
Planned actions for macos (arm64):

  Packages
    1. Install Homebrew   [skip: already present at /opt/homebrew]

```

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "add Homebrew bootstrap step to install.sh

Detects existing brew installs via command -v, falls back to the official
curl-pipe installer with NONINTERACTIVE=1 when absent. After install,
sources brew shellenv into the current shell so subsequent plan_* steps
that depend on brew can find it."
```

### Task 5: Add brew package handlers (zsh, spaceship, tfenv)

**Files:**
- Modify: `install.sh`

Adds three brew formula installs. Each handler must:
- Skip if the formula is already installed.
- On `--migrate`, detect a pre-existing manual git-clone install, remove it, then brew install.
- Without `--migrate`, warn and skip if a manual install is present.

- [ ] **Step 1: Add `plan_brew_packages` and helper functions**

Insert above `register_plan`:

```bash
# -------- Brew packages --------

brew_formula_installed() {
	brew list --formula "$1" > /dev/null 2>&1
}

plan_brew_formula() {
	# Args: formula_name, do_function_name
	local name="$1" fn="$2"
	if brew_formula_installed "$name"; then
		planned_action "Packages" "$fn" "brew install $name" "skip: already present"
	else
		planned_action "Packages" "$fn" "brew install $name"
	fi
}

plan_zsh() {
	# On macOS the system zsh is always present and is the canonical login shell;
	# we don't install brew's zsh unless the system one is unexpectedly missing.
	if [ "$OS" = "macos" ]; then
		if command -v zsh > /dev/null 2>&1; then
			planned_action "Packages" "do_zsh" "Install zsh" "skip: already present at $(command -v zsh)"
		else
			planned_action "Packages" "do_zsh" "brew install zsh"
		fi
	else
		# Linux: zsh is installed via apt in plan_linux_prereqs (Task 12),
		# because it needs to be in /etc/shells. Nothing to do here.
		return 0
	fi
}

do_zsh() {
	if command -v zsh > /dev/null 2>&1; then return 0; fi
	brew install zsh
}

plan_spaceship() {
	# Detect pre-existing manual git clone install.
	local manual="$HOME/.oh-my-zsh/custom/themes/spaceship-prompt"
	if [ -d "$manual" ]; then
		if [ "$MIGRATE" -eq 1 ]; then
			planned_action "Packages" "do_spaceship" "brew install spaceship" "migrate: remove $manual git clone first"
		else
			planned_action "Packages" "do_spaceship" "brew install spaceship" "skip: manual install present (re-run with --migrate to replace)"
		fi
		return
	fi
	plan_brew_formula spaceship do_spaceship
}

do_spaceship() {
	local manual="$HOME/.oh-my-zsh/custom/themes/spaceship-prompt"
	if [ -d "$manual" ]; then
		if [ "$MIGRATE" -eq 1 ]; then
			rm -rf "$manual"
		else
			return 0  # plan said skip; respect it
		fi
	fi
	if brew_formula_installed spaceship; then return 0; fi
	brew install spaceship
}

plan_tfenv() {
	local manual="$HOME/.tfenv"
	if [ -d "$manual/.git" ]; then
		if [ "$MIGRATE" -eq 1 ]; then
			planned_action "Packages" "do_tfenv" "brew install tfenv" "migrate: remove $manual git clone first"
		else
			planned_action "Packages" "do_tfenv" "brew install tfenv" "skip: manual install present (re-run with --migrate to replace)"
		fi
		return
	fi
	plan_brew_formula tfenv do_tfenv
}

do_tfenv() {
	local manual="$HOME/.tfenv"
	if [ -d "$manual/.git" ]; then
		if [ "$MIGRATE" -eq 1 ]; then
			rm -rf "$manual"
		else
			return 0
		fi
	fi
	if brew_formula_installed tfenv; then return 0; fi
	brew install tfenv
}
```

- [ ] **Step 2: Wire into `register_plan`**

Update `register_plan`:

```bash
register_plan() {
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
}
```

- [ ] **Step 3: Static + dry-run check**

```bash
shellcheck install.sh
bash -n install.sh
./install.sh --dry-run
```

Expected (on maintainer's Mac, without `--migrate`):
```
Planned actions for macos (arm64):

  Packages
    1. Install Homebrew   [skip: already present at /opt/homebrew]
    2. Install zsh   [skip: already present at /bin/zsh]
    3. brew install spaceship   [skip: manual install present (re-run with --migrate to replace)]
    4. brew install tfenv   [skip: manual install present (re-run with --migrate to replace)]

```

- [ ] **Step 4: Dry-run with `--migrate`**

Run: `./install.sh --dry-run --migrate`

Expected — the spaceship and tfenv lines now show migrate status:
```
    3. brew install spaceship   [migrate: remove /Users/lucas/.oh-my-zsh/custom/themes/spaceship-prompt git clone first]
    4. brew install tfenv   [migrate: remove /Users/lucas/.tfenv git clone first]
```

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "add brew package handlers for zsh, spaceship, tfenv

zsh on macOS is a skip (system zsh is the login shell); on Linux it's
deferred to apt (Task 12) since /etc/shells registration matters.
spaceship and tfenv each detect pre-existing manual git-clone installs:
without --migrate they warn and skip; with --migrate they rm -rf the
manual install before brew installs the formula."
```

### Task 6: Add Maple Mono NF font handler (cask on macOS, GitHub release on Linux)

**Files:**
- Modify: `install.sh`

The font replaces `powerline` / `fonts-powerline` from the original script. macOS gets `brew install --cask font-maple-mono-nf`. Linux has no cask system, so we download from GitHub releases and install into `~/.local/share/fonts/`.

- [ ] **Step 1: Add the font handler functions**

Insert above `register_plan`:

```bash
# -------- Font: Maple Mono NF --------

FONT_LINUX_RELEASE_API="https://api.github.com/repos/subframe7536/maple-font/releases/latest"
FONT_LINUX_INSTALL_DIR="$HOME/.local/share/fonts/MapleMonoNF"

brew_cask_installed() {
	brew list --cask "$1" > /dev/null 2>&1
}

font_linux_installed() {
	command -v fc-list > /dev/null 2>&1 && fc-list 2>/dev/null | grep -qi 'Maple Mono NF'
}

plan_font() {
	case "$OS" in
		macos)
			if brew_cask_installed font-maple-mono-nf; then
				planned_action "Packages" "do_font" "brew install --cask font-maple-mono-nf" "skip: already present"
			else
				planned_action "Packages" "do_font" "brew install --cask font-maple-mono-nf"
			fi
			;;
		linux)
			if font_linux_installed; then
				planned_action "Packages" "do_font" "Install Maple Mono NF from github.com/subframe7536/maple-font releases" "skip: already present"
			else
				planned_action "Packages" "do_font" "Install Maple Mono NF from github.com/subframe7536/maple-font releases into $FONT_LINUX_INSTALL_DIR"
			fi
			;;
	esac
}

do_font() {
	case "$OS" in
		macos)
			if brew_cask_installed font-maple-mono-nf; then return 0; fi
			brew install --cask font-maple-mono-nf
			;;
		linux)
			if font_linux_installed; then return 0; fi
			mkdir -p "$FONT_LINUX_INSTALL_DIR"
			local asset_url
			asset_url=$(curl -fsSL "$FONT_LINUX_RELEASE_API" \
				| grep -E '"browser_download_url".*MapleMono-NF.*\.zip"' \
				| head -1 \
				| sed -E 's/.*"(https[^"]+)".*/\1/')
			if [ -z "$asset_url" ]; then
				echo "Could not find Maple Mono NF zip in latest release" >&2
				return 1
			fi
			local tmpdir
			tmpdir=$(mktemp -d)
			# shellcheck disable=SC2064
			trap "rm -rf '$tmpdir'" RETURN
			curl -fsSL "$asset_url" -o "$tmpdir/MapleMono-NF.zip"
			unzip -q "$tmpdir/MapleMono-NF.zip" -d "$FONT_LINUX_INSTALL_DIR"
			fc-cache -fv "$FONT_LINUX_INSTALL_DIR" > /dev/null
			;;
	esac
}
```

- [ ] **Step 2: Wire into `register_plan`**

```bash
register_plan() {
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
	plan_font
}
```

- [ ] **Step 3: Static + dry-run check**

```bash
shellcheck install.sh
./install.sh --dry-run
```

Expected (new line on Mac):
```
    5. brew install --cask font-maple-mono-nf
```

(Or `[skip: already present]` if the cask is already installed on this machine.)

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "add Maple Mono NF font handler

On macOS uses the font-maple-mono-nf Homebrew cask. On Linux fetches the
latest release zip from github.com/subframe7536/maple-font, extracts to
~/.local/share/fonts/MapleMonoNF/, and refreshes the font cache via
fc-cache. Replaces the apt-only powerline / fonts-powerline pair from the
old script."
```

### Task 7: Add Oh My Zsh handler

**Files:**
- Modify: `install.sh`

Oh My Zsh has no Homebrew formula. Stays as the official curl-pipe install. Skipped when `~/.oh-my-zsh` already exists.

- [ ] **Step 1: Add the handler**

Insert above `register_plan`:

```bash
# -------- Oh My Zsh (no brew formula available) --------

OMZ_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"

plan_omz() {
	if [ -d "$HOME/.oh-my-zsh" ]; then
		planned_action "Curl installs (no brew formula available)" "do_omz" "Install Oh My Zsh" "skip: $HOME/.oh-my-zsh already present"
	else
		planned_action "Curl installs (no brew formula available)" "do_omz" "Install Oh My Zsh (curl-install from $OMZ_INSTALL_URL)"
	fi
}

do_omz() {
	if [ -d "$HOME/.oh-my-zsh" ]; then return 0; fi
	RUNZSH=no CHSH=no sh -c "$(curl -fsSL "$OMZ_INSTALL_URL")" "" --unattended
}
```

- [ ] **Step 2: Wire into `register_plan`**

```bash
register_plan() {
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
	plan_font
	plan_omz
}
```

- [ ] **Step 3: Dry-run check**

```bash
./install.sh --dry-run
```

Expected: a new section header `Curl installs (no brew formula available)` with one entry, on the maintainer's Mac showing `[skip: $HOME/.oh-my-zsh already present]`.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "add Oh My Zsh handler

Stays as a curl-pipe install since there's no Homebrew formula. Skipped
when ~/.oh-my-zsh already exists. Runs the official installer with
RUNZSH=no CHSH=no --unattended so it doesn't try to switch the user's
login shell mid-script."
```

### Task 8: Add dotfile symlink handler (with `--migrate` for stale copies)

**Files:**
- Modify: `install.sh`

Symlinks `.zshrc`, `.aliases`, `.functions`, `.gitignore` from the repo into `$HOME`. The behavior matrix is in spec §6: handles already-correct-symlink (no-op), absent (create), regular-file-identical (replace, no `--migrate` needed), regular-file-differing (require `--migrate` + backup), symlink-elsewhere (require `--migrate`).

- [ ] **Step 1: Add the symlink handler**

Insert above `register_plan`. Note: bash function names cannot start with a dot, so the per-file functions use the bare basename (no leading dot) and `sym_fn_name` maps from the dotted filename to the function name.

```bash
# -------- Dotfile symlinks --------

SYMLINK_FILES=(.zshrc .aliases .functions .gitignore)

sym_fn_name() {
	# Map ".zshrc" -> "do_symlink_zshrc" (bash function names can't start with a dot)
	local n="${1#.}"
	echo "do_symlink_$n"
}

dotfile_state() {
	# Echoes one of: ok, absent, identical, differing, symlink_other
	local src="$1" dst="$2"
	if [ -L "$dst" ]; then
		if [ "$(readlink "$dst")" = "$src" ]; then
			echo ok
		else
			echo symlink_other
		fi
	elif [ ! -e "$dst" ]; then
		echo absent
	elif cmp -s "$src" "$dst"; then
		echo identical
	else
		echo differing
	fi
}

plan_symlinks() {
	for name in "${SYMLINK_FILES[@]}"; do
		local src="$REPO_DIR/$name"
		local dst="$HOME/$name"
		local fn
		fn=$(sym_fn_name "$name")
		local state
		state=$(dotfile_state "$src" "$dst")
		case "$state" in
			ok)
				planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "skip: already linked"
				;;
			absent)
				planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "new"
				;;
			identical)
				planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "convert: regular file, identical content"
				;;
			differing)
				if [ "$MIGRATE" -eq 1 ]; then
					planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "migrate: back up $dst then replace"
				else
					planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "skip: local edits present (re-run with --migrate)"
				fi
				;;
			symlink_other)
				if [ "$MIGRATE" -eq 1 ]; then
					planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "migrate: replace symlink currently pointing at $(readlink "$dst")"
				else
					planned_action "Symlinks" "$fn" "ln -sfn $src $dst" "skip: symlink points elsewhere (re-run with --migrate)"
				fi
				;;
		esac
	done
}

do_symlink_one() {
	local name="$1"
	local src="$REPO_DIR/$name"
	local dst="$HOME/$name"
	local state
	state=$(dotfile_state "$src" "$dst")
	case "$state" in
		ok) return 0 ;;
		absent|identical)
			ln -sfn "$src" "$dst"
			;;
		differing|symlink_other)
			if [ "$MIGRATE" -ne 1 ]; then return 0; fi
			if [ -L "$dst" ]; then
				rm "$dst"
			else
				local ts
				ts=$(date +%Y%m%d-%H%M%S)
				mv "$dst" "$dst.bak.$ts"
			fi
			ln -sfn "$src" "$dst"
			;;
	esac
}

do_symlink_zshrc()     { do_symlink_one .zshrc; }
do_symlink_aliases()   { do_symlink_one .aliases; }
do_symlink_functions() { do_symlink_one .functions; }
do_symlink_gitignore() { do_symlink_one .gitignore; }
```

- [ ] **Step 2: Wire into `register_plan`**

```bash
register_plan() {
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
	plan_font
	plan_omz
	plan_symlinks
}
```

- [ ] **Step 3: Static + dry-run check**

```bash
shellcheck install.sh
./install.sh --dry-run
```

Expected on maintainer's Mac: a `Symlinks` section with 4 entries. `.aliases`, `.functions`, `.gitignore` show `[convert: regular file, identical content]`. `.zshrc` shows `[skip: local edits present ...]` *if* the Mac `~/.zshrc` still differs from the post-Task-2 repo `.zshrc` (it currently does, because of the 3 user-specific lines). After Task 9 writes `~/.extra` and the user removes those 3 lines from `~/.zshrc`, this becomes `[convert: regular file, identical content]`. **For now, expect `[skip]` on `.zshrc`** unless running with `--migrate`.

- [ ] **Step 4: Dry-run with `--migrate` to verify the migrate text appears**

```bash
./install.sh --dry-run --migrate
```

Expected `.zshrc` line:
```
   N. ln -sfn /Users/lucas/Repos/.../.zshrc /Users/lucas/.zshrc   [migrate: back up /Users/lucas/.zshrc then replace]
```

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "add dotfile symlink handler with migration semantics

Each of .zshrc/.aliases/.functions/.gitignore gets symlinked from the
repo into \$HOME. State detection covers: already-correct-symlink (no-op),
absent (create), regular-file byte-identical to repo (replace; safe),
regular-file differing (requires --migrate + timestamped backup),
symlink-pointing-elsewhere (requires --migrate). Aligns with spec §6."
```

### Task 9: Add gitconfig include, `~/.extra` writer, spaceship theme symlink, Linux brew shellenv

**Files:**
- Modify: `install.sh`

Four small Config-section handlers that close out the spec.

- [ ] **Step 1: Add the four handlers**

Insert above `register_plan`:

```bash
# -------- Config --------

GITCONFIG_INCLUDE="$REPO_DIR/.gitconfig"
EXTRA_FILE="$HOME/.extra"
SPACESHIP_THEME_LINK="$HOME/.oh-my-zsh/custom/themes/spaceship.zsh-theme"

plan_gitconfig_include() {
	if git config --global --get-all include.path 2>/dev/null | grep -qxF "$GITCONFIG_INCLUDE"; then
		planned_action "Config" "do_gitconfig_include" "git config --global --add include.path $GITCONFIG_INCLUDE" "skip: already included"
	else
		planned_action "Config" "do_gitconfig_include" "git config --global --add include.path $GITCONFIG_INCLUDE"
	fi
}

do_gitconfig_include() {
	if git config --global --get-all include.path 2>/dev/null | grep -qxF "$GITCONFIG_INCLUDE"; then
		return 0
	fi
	git config --global --add include.path "$GITCONFIG_INCLUDE"
}

plan_extra_file() {
	# Only relevant on macOS (the Secretive SSH agent socket is macOS-specific).
	if [ "$OS" != "macos" ]; then return 0; fi
	if [ -f "$EXTRA_FILE" ]; then
		planned_action "Config" "do_extra_file" "Write $EXTRA_FILE with SSH_AUTH_SOCK + PATH=~/.local/bin" "skip: $EXTRA_FILE already exists"
	else
		planned_action "Config" "do_extra_file" "Write $EXTRA_FILE with SSH_AUTH_SOCK + PATH=~/.local/bin" "new"
	fi
}

do_extra_file() {
	[ "$OS" = "macos" ] || return 0
	[ -f "$EXTRA_FILE" ] && return 0
	cat > "$EXTRA_FILE" <<'EOF'
# Secretive Agent
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
export PATH="$HOME/.local/bin:$PATH"
EOF
}

plan_spaceship_theme_link() {
	local target
	target="$(brew_prefix)/opt/spaceship/spaceship.zsh-theme"
	if [ -L "$SPACESHIP_THEME_LINK" ] && [ "$(readlink "$SPACESHIP_THEME_LINK")" = "$target" ]; then
		planned_action "Symlinks" "do_spaceship_theme_link" "ln -sfn $target $SPACESHIP_THEME_LINK" "skip: already linked"
	else
		planned_action "Symlinks" "do_spaceship_theme_link" "ln -sfn $target $SPACESHIP_THEME_LINK"
	fi
}

do_spaceship_theme_link() {
	local target
	target="$(brew_prefix)/opt/spaceship/spaceship.zsh-theme"
	mkdir -p "$(dirname "$SPACESHIP_THEME_LINK")"
	ln -sfn "$target" "$SPACESHIP_THEME_LINK"
}

plan_linux_brew_shellenv() {
	[ "$OS" = "linux" ] || return 0
	if [ -f "$HOME/.zprofile" ] && grep -q 'brew shellenv' "$HOME/.zprofile"; then
		planned_action "Config" "do_linux_brew_shellenv" "Append brew shellenv to ~/.zprofile" "skip: already present"
	else
		planned_action "Config" "do_linux_brew_shellenv" "Append 'eval \"\$($(brew_prefix)/bin/brew shellenv)\"' to ~/.zprofile"
	fi
}

do_linux_brew_shellenv() {
	[ "$OS" = "linux" ] || return 0
	if [ -f "$HOME/.zprofile" ] && grep -q 'brew shellenv' "$HOME/.zprofile"; then return 0; fi
	echo "eval \"\$($(brew_prefix)/bin/brew shellenv)\"" >> "$HOME/.zprofile"
}
```

- [ ] **Step 2: Wire into `register_plan`**

```bash
register_plan() {
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
	plan_font
	plan_omz
	plan_symlinks
	plan_spaceship_theme_link
	plan_gitconfig_include
	plan_extra_file
	plan_linux_brew_shellenv
}
```

- [ ] **Step 3: Static + dry-run check**

```bash
shellcheck install.sh
./install.sh --dry-run
```

Expected new entries (Mac):
- A `Config` section with `git config --global --add include.path ...` (no `skip` since maintainer's `~/.gitconfig` lacks the include) and `Write ~/.extra ... [new]`.
- The spaceship theme symlink may show `[skip: already linked]` if the manual install symlink happens to match brew's path (it won't, since brew isn't yet the source).

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "add config handlers: gitconfig include, ~/.extra, theme link, linux shellenv

plan_gitconfig_include appends the repo's .gitconfig to ~/.gitconfig's
include.path list (idempotent — checks existing value first).
plan_extra_file writes ~/.extra with the maintainer's machine-specific
SSH_AUTH_SOCK + PATH lines on macOS only, and never overwrites an
existing ~/.extra. plan_spaceship_theme_link points the OMZ custom theme
symlink at brew's spaceship prefix. plan_linux_brew_shellenv ensures
~/.zprofile sources brew on Linux (where the brew installer only writes
to ~/.profile, which zsh doesn't read)."
```

### Task 10: Add Linux apt prerequisites + post-install hint

**Files:**
- Modify: `install.sh`

The final bits: apt prerequisites for Linuxbrew bootstrap (curl, git, build-essential, procps, file) and apt zsh (since it registers in /etc/shells). Plus the existing "chsh hint" trailing message.

- [ ] **Step 1: Add Linux prereq handler and chsh hint**

Insert above `register_plan`:

```bash
# -------- Linux prereqs --------

LINUX_APT_PACKAGES=(curl git build-essential procps file zsh unzip)

apt_package_installed() {
	dpkg -s "$1" > /dev/null 2>&1
}

plan_linux_prereqs() {
	[ "$OS" = "linux" ] || return 0
	local missing=()
	for p in "${LINUX_APT_PACKAGES[@]}"; do
		if ! apt_package_installed "$p"; then
			missing+=("$p")
		fi
	done
	if [ "${#missing[@]}" -eq 0 ]; then
		planned_action "Packages" "do_linux_prereqs" "sudo apt-get install ${LINUX_APT_PACKAGES[*]}" "skip: all present"
	else
		planned_action "Packages" "do_linux_prereqs" "sudo apt-get install ${missing[*]}"
	fi
}

do_linux_prereqs() {
	[ "$OS" = "linux" ] || return 0
	local missing=()
	for p in "${LINUX_APT_PACKAGES[@]}"; do
		if ! apt_package_installed "$p"; then
			missing+=("$p")
		fi
	done
	if [ "${#missing[@]}" -eq 0 ]; then return 0; fi
	sudo apt-get update
	sudo apt-get install -y "${missing[@]}"
}

# -------- Post-install hint --------

print_chsh_hint() {
	local zsh_path
	zsh_path=$(command -v zsh || true)
	if [ -n "$zsh_path" ] && [ "${SHELL:-}" != "$zsh_path" ]; then
		echo
		echo "To finish setup, change your login shell to zsh:"
		echo "  chsh -s \"$zsh_path\""
	fi
}
```

- [ ] **Step 2: Wire prereqs into `register_plan` as the **first** action on Linux**

```bash
register_plan() {
	plan_linux_prereqs    # must come before plan_homebrew on Linux
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
	plan_font
	plan_omz
	plan_symlinks
	plan_spaceship_theme_link
	plan_gitconfig_include
	plan_extra_file
	plan_linux_brew_shellenv
}
```

(`plan_linux_prereqs` is a no-op on macOS, so this is safe.)

- [ ] **Step 3: Update `main()` to call `print_chsh_hint` after execute_plan**

Replace the existing `main()` with:

```bash
main() {
	register_plan
	render_plan
	if [ "$DRY_RUN" -eq 1 ]; then
		exit 0
	fi
	if [ "${#PLANNED_ACTIONS[@]}" -eq 0 ]; then
		echo "Nothing to do."
		exit 0
	fi
	prompt_or_proceed
	execute_plan
	echo
	echo "Done."
	print_chsh_hint
}
```

- [ ] **Step 4: Static + dry-run check**

```bash
shellcheck install.sh
./install.sh --dry-run
```

Expected on Mac: no change (prereqs is a no-op). The plan should be complete now — all spec sections covered.

- [ ] **Step 5: Full dry-run with `--migrate` on the Mac, verify against spec §12 example**

Run: `./install.sh --dry-run --migrate`

Capture the output. Compare to the example output in [spec §12](../specs/2026-05-11-cross-platform-install-design.md). They should match in structure (section headers, action descriptions, status annotations). Numbering may differ slightly — that's fine.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "add Linux apt prereqs, wire main() with post-install chsh hint

plan_linux_prereqs ensures Linuxbrew's bootstrap dependencies and apt-zsh
are installed up-front (apt-zsh registers in /etc/shells, which brew's
zsh does not). Wired as the first action on Linux. Restores the
chsh-to-zsh hint at the end of a successful run, matching prior script
behavior."
```

---

## Phase C — Documentation

### Task 11: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite `README.md`**

Replace the entire contents with:

```markdown
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
```

- [ ] **Step 2: Verify the markdown renders**

Run: `cat README.md | head -40`
Expected: clean text, no leftover placeholders.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "update README for cross-platform install.sh

Documents the new --dry-run / --yes / --migrate flags, the Homebrew-first
package set (incl. Maple Mono NF), and the Linux/macOS requirements.
Keeps the notes on .bashrc and the .gitconfig [include] behavior."
```

---

## Phase D — End-to-end verification on the maintainer's Mac

### Task 12: Run `--dry-run` on the maintainer's Mac and verify output

**Files:** none modified.

The goal is to confirm the dry-run output matches the spec §12 example and that the plan is complete and accurate before running `--migrate` for real.

- [ ] **Step 1: Default-flags dry-run**

Run: `./install.sh --dry-run`

Expected output (numbers may differ; statuses should match):
- `Homebrew install` → `[skip: already present at /opt/homebrew]`
- `Install zsh` → `[skip: already present at /bin/zsh]`
- `brew install spaceship` → `[skip: manual install present (re-run with --migrate to replace)]`
- `brew install tfenv` → `[skip: manual install present (re-run with --migrate to replace)]`
- `brew install --cask font-maple-mono-nf` → either `[skip]` or pending, depending on current state
- Oh My Zsh → `[skip: $HOME/.oh-my-zsh already present]`
- `.aliases`, `.functions`, `.gitignore` symlinks → `[convert: regular file, identical content]`
- `.zshrc` symlink → `[skip: local edits present (re-run with --migrate)]` (Mac `~/.zshrc` has the 3 extra Secretive lines; will only be `[convert: regular file, identical content]` after `~/.extra` is created and the user manually removes those lines from `~/.zshrc` — or via `--migrate` which backs it up and replaces)
- spaceship theme symlink → pending, since current symlink points at the git-clone path, not the brew prefix
- `git config --global --add include.path` → pending
- `Write ~/.extra` → `[new]`

- [ ] **Step 2: Migrate dry-run**

Run: `./install.sh --dry-run --migrate`

Expected differences from Step 1:
- `brew install spaceship` → `[migrate: remove /Users/lucas/.oh-my-zsh/custom/themes/spaceship-prompt git clone first]`
- `brew install tfenv` → `[migrate: remove /Users/lucas/.tfenv git clone first]`
- `.zshrc` symlink → `[migrate: back up /Users/lucas/.zshrc then replace]`

- [ ] **Step 3: Compare against spec example**

Open `docs/superpowers/specs/2026-05-11-cross-platform-install-design.md` §12 side-by-side with the `--dry-run --migrate` output. Verify all spec-listed actions appear (numbering may differ).

- [ ] **Step 4: No commit (verification only).**

### Task 13: Run `--migrate` on the maintainer's Mac and verify post-conditions

**Files:** none in the repo modified (this changes the user's `$HOME`).

This is the actual migration — destructive but planned. The user must explicitly confirm at the prompt.

- [ ] **Step 1: Run with `--migrate`**

Run: `./install.sh --migrate`

Review the printed plan. Answer `y` at the `Proceed? [y/N]` prompt.

- [ ] **Step 2: Verify post-conditions**

Run these checks and confirm each:

```bash
# tfenv migrated to brew
[ ! -d "$HOME/.tfenv" ] && echo "OK: ~/.tfenv removed"
brew list --formula tfenv > /dev/null && echo "OK: brew tfenv installed"
command -v terraform > /dev/null && echo "OK: terraform on PATH"

# spaceship migrated to brew
[ ! -d "$HOME/.oh-my-zsh/custom/themes/spaceship-prompt" ] && echo "OK: spaceship git clone removed"
brew list --formula spaceship > /dev/null && echo "OK: brew spaceship installed"
[ "$(readlink "$HOME/.oh-my-zsh/custom/themes/spaceship.zsh-theme")" = "$(brew --prefix)/opt/spaceship/spaceship.zsh-theme" ] && echo "OK: theme symlink points at brew"

# font cask installed
brew list --cask font-maple-mono-nf > /dev/null && echo "OK: Maple Mono NF cask installed"

# symlinks correct
for f in .zshrc .aliases .functions .gitignore; do
	[ "$(readlink "$HOME/$f")" = "$(pwd)/$f" ] && echo "OK: ~/$f -> repo"
done

# .zshrc backup exists (since the Mac's .zshrc differed from the repo's)
ls "$HOME/.zshrc.bak."* > /dev/null 2>&1 && echo "OK: .zshrc backed up"

# gitconfig include added
git config --global --get-all include.path | grep -qxF "$(pwd)/.gitconfig" && echo "OK: gitconfig include present"

# ~/.extra exists with the Secretive lines
grep -q 'SSH_AUTH_SOCK' "$HOME/.extra" && echo "OK: ~/.extra written"
```

Every line should print an `OK:` confirmation.

- [ ] **Step 3: Sanity-check a fresh shell**

Run: `zsh -l -c 'echo $PATH; which terraform; which spaceship'`
Expected: `PATH` includes `/opt/homebrew/bin`; both `terraform` and `spaceship` resolve to brew's prefix (`/opt/homebrew/...`).

- [ ] **Step 4: Re-run with no flags to confirm idempotency**

Run: `./install.sh --dry-run`

Expected: every action shows `[skip: ...]` or `[skip: already linked]` / `[skip: already present]` / `[skip: $HOME/.extra already exists]`. The plan should be entirely skips on the second run.

- [ ] **Step 5: No commit (verification only).**

---

## Phase E — Open the pull request

### Task 14: Push the branch and open the PR

**Files:** none modified.

- [ ] **Step 1: Push the worktree branch**

Run: `git push -u origin claude/modest-poitras-96e985`

(If the remote name is `origin` and pushing to that remote succeeds.)

- [ ] **Step 2: Confirm the remote and resolve PR target**

Run: `git remote -v` to see the remote URL. The repo lives at `https://codeberg.org/lucascantor/dotfiles.git` per the README, so the PR is opened on Codeberg, not GitHub.

Codeberg uses Forgejo/Gitea. The `gh` CLI doesn't support Codeberg. The PR must be opened either:
- Via the Codeberg web UI: visit `https://codeberg.org/lucascantor/dotfiles/compare/main...claude/modest-poitras-96e985` and open the PR from there, or
- Via the `tea` CLI if installed (`brew install tea`), or
- Via a `curl` against the Forgejo API with the user's PAT.

Default to the web UI for the simplest path — just print the compare URL and let the user click through.

- [ ] **Step 3: Print PR title and body for the user to paste**

Print to stdout:

**Title:** `make install.sh cross-platform with Homebrew, dry-run, and migration`

**Body:**

```
## Summary

- Rewrites `install.sh` to support macOS and Debian/Ubuntu Linux from a single script, using Homebrew as the canonical package manager on both OSes.
- Adds `--dry-run`, `--yes`, and `--migrate` flags. Every run prints a planned-actions list before doing anything; `--dry-run` exits after printing; `--migrate` enables destructive replacement of pre-existing manual installs (e.g. `~/.tfenv` git clone → `brew tfenv`).
- Replaces apt-only `powerline` / `fonts-powerline` with the Maple Mono NF font (Homebrew cask on macOS, GitHub release on Linux).
- Sources of truth synced from the maintainer's Mac: `.gitconfig` reorg + `[pull] rebase = true` / `[init] defaultBranch = main` additions; `.zshrc` no longer exports the legacy `~/.tfenv/bin` PATH.

Design spec: `docs/superpowers/specs/2026-05-11-cross-platform-install-design.md`

## Test plan

- [x] `./install.sh --dry-run` on the maintainer's Mac matches the spec §12 expected output
- [x] `./install.sh --dry-run --migrate` correctly annotates migrate actions
- [x] `./install.sh --migrate` (with confirmation) successfully migrates `~/.tfenv` and spaceship-prompt to Homebrew, replaces stale dotfile copies with symlinks, writes `~/.extra`, adds `[include]` to `~/.gitconfig`
- [x] Second `./install.sh --dry-run` after migration shows every action as `[skip: ...]` (idempotency)
- [ ] Linux smoke test in `ubuntu:24.04` container — out of scope for this PR
```

- [ ] **Step 4: No commit (PR opens via the web UI).**

---

## Self-review checklist

After finishing all tasks, verify against the spec:

- **§3 Architecture:** covered by Task 3 (scaffolding) + each subsequent task.
- **§4 Package mapping:** covered by Tasks 4 (homebrew) + 5 (zsh/spaceship/tfenv) + 6 (font) + 7 (omz) + 10 (linux prereqs).
- **§5 CLI surface:** covered by Task 3 (arg parsing).
- **§6 Migration semantics:** covered by Task 5 (brew package migrations) + Task 8 (symlink migrations).
- **§7 Repo content sync:** covered by Tasks 1–2.
- **§8 `~/.extra` handling:** covered by Task 9.
- **§9 `.zshrc` and shell environment:** covered by Task 2 (.zshrc edit) + Task 9 (linux brew shellenv).
- **§10 `.gitconfig` integration:** covered by Task 9.
- **§11 Idempotency model:** covered across all `plan_*` detection.
- **§12 Plan output format:** verified in Task 12.
- **§13 Error handling:** `set -euo pipefail` in Task 3; sudo surfacing in Task 10.
- **§14 README updates:** covered by Task 11.
- **§15 Test plan:** covered by Tasks 12–13 (Mac); Linux Docker smoke test deferred (out-of-scope per §16).

No placeholders. No unreferenced types or functions. Function names are consistent across tasks.
