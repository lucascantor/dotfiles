# Keep $PATH free of duplicates (first occurrence wins), so the prepends below
# don't stack up entry after entry in nested shells.
typeset -U path PATH

# Homebrew
# macOS's path_helper (run from /etc/zprofile) appends /etc/paths.d/homebrew
# *after* the entries in /etc/paths, so /usr/bin lands ahead of
# /opt/homebrew/bin and the system copies of openssl, python3 and pip3 shadow
# Homebrew's. Re-prepend the prefix here to put Homebrew back in front.
# `brew shellenv` prints nothing when the prefix is already leading $PATH, so
# this stays idempotent in nested shells. Prefixes are probed in order:
# Apple Silicon, Intel, Linuxbrew.
for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
	if [ -x "$brew_bin" ]; then
		eval "$("$brew_bin" shellenv)"
		break
	fi
done
unset brew_bin

# Oh My Zsh
export ZSH="${HOME}/.oh-my-zsh"

# Oh My Zsh Theme
ZSH_THEME="spaceship"
export SPACESHIP_DIR_TRUNC=0

# Oh My Zsh Plugins
plugins=(git)

# Source Oh My Zsh
source $ZSH/oh-my-zsh.sh

# Load the shell dotfiles, and then some:
# * ~/.path can be used to extend `$PATH`
# * ~/.extra can be used for other settings you don’t want to commit
for file in ~/.{path,zsh_prompt,exports,aliases,functions,extra}; do
	[ -r "$file" ] && [ -f "$file" ] && source "$file";
done;
unset file;

# Enable tab completion for `g` by marking it as an alias for `git`
if type _git &> /dev/null; then
	complete -o default -o nospace -F _git g;
fi;

# Enable tab completion for Terraform
autoload -U +X bashcompinit && bashcompinit
command -v terraform > /dev/null && complete -o nospace -C terraform terraform

# Add ~/.tfenv/bin to $PATH
export PATH="$HOME/.tfenv/bin:$PATH"

# Add ~/.local/bin to $PATH (sfw and other user-local binaries)
export PATH="$HOME/.local/bin:$PATH"