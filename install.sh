#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

# .bashrc preserved as-is so local PATH additions survive;
# .gitconfig handled via [include] to preserve identity/signing config.
SYMLINK_FILES=(.zshrc .aliases .functions .gitignore)

ensure_packages() {
	if command -v zsh > /dev/null 2>&1 \
		&& dpkg -s powerline > /dev/null 2>&1 \
		&& dpkg -s fonts-powerline > /dev/null 2>&1; then
		return
	fi
	echo "Installing zsh, powerline, fonts-powerline..."
	sudo apt-get update
	sudo apt-get install -y zsh powerline fonts-powerline curl git
}

ensure_oh_my_zsh() {
	[ -d "$HOME/.oh-my-zsh" ] && return
	echo "Installing Oh My Zsh..."
	RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
}

ensure_spaceship_theme() {
	local zsh_custom="$HOME/.oh-my-zsh/custom"
	if [ ! -d "$zsh_custom/themes/spaceship-prompt" ]; then
		echo "Installing Spaceship prompt theme..."
		git clone --depth=1 https://github.com/spaceship-prompt/spaceship-prompt.git "$zsh_custom/themes/spaceship-prompt"
	fi
	ln -sfn "$zsh_custom/themes/spaceship-prompt/spaceship.zsh-theme" "$zsh_custom/themes/spaceship.zsh-theme"
}

ensure_tfenv() {
	[ -d "$HOME/.tfenv" ] && return
	echo "Installing tfenv..."
	git clone --depth=1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
}

create_symlinks() {
	for name in "${SYMLINK_FILES[@]}"; do
		echo "Linking ~/$name -> $SCRIPT_DIR/$name"
		ln -sfn "$SCRIPT_DIR/$name" "$HOME/$name"
	done
}

# Layer the dotfiles .gitconfig via include directive so user identity / SSH signing in ~/.gitconfig stay intact.
merge_gitconfig() {
	local include_path="$SCRIPT_DIR/.gitconfig"
	if git config --global --get-all include.path 2> /dev/null | grep -qxF "$include_path"; then
		return
	fi
	echo "Adding [include] for $include_path to ~/.gitconfig"
	git config --global --add include.path "$include_path"
}

print_chsh_hint() {
	local zsh_path
	zsh_path=$(command -v zsh)
	if [ "${SHELL:-}" != "$zsh_path" ]; then
		echo ""
		echo "To finish setup, change your login shell to zsh:"
		echo "  chsh -s \"$zsh_path\""
	fi
}

ensure_packages
ensure_oh_my_zsh
ensure_spaceship_theme
ensure_tfenv
create_symlinks
merge_gitconfig
print_chsh_hint
