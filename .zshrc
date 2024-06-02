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
complete -o nospace -C /usr/bin/terraform terraform

# Add ~/.tfenv/bin to $PATH
export PATH="$HOME/.tfenv/bin:$PATH"