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
