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

# -------- Plan registration (filled in by subsequent tasks) --------

register_plan() {
	plan_homebrew
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
