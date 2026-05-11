#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034
REPO_DIR="$SCRIPT_DIR"

# -------- Flags --------
DRY_RUN=0
ASSUME_YES=0
# shellcheck disable=SC2034
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

# shellcheck disable=SC2034
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
	for entry in "${PLANNED_ACTIONS[@]+"${PLANNED_ACTIONS[@]}"}"; do
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
	for entry in "${PLANNED_ACTIONS[@]+"${PLANNED_ACTIONS[@]}"}"; do
		local rest="${entry#*|}"
		local fn="${rest%%|*}"
		rest="${rest#*|}"
		local desc="${rest%%|*}"
		local status="${rest#*|}"
		# Entries whose status starts with "skip:" are documented no-ops.
		# Skip them outright so execution output doesn't contradict the plan.
		if [[ "$status" == skip:* ]]; then
			continue
		fi
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
		# Linux: zsh is installed via apt in plan_linux_prereqs (Task 10),
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
				| grep -E '"browser_download_url".*MapleMono-NF\.zip"' \
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
			fc-cache -f "$FONT_LINUX_INSTALL_DIR" > /dev/null
			;;
	esac
}

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

# -------- Plan registration (filled in by subsequent tasks) --------

register_plan() {
	plan_homebrew
	plan_zsh
	plan_spaceship
	plan_tfenv
	plan_font
	plan_omz
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
