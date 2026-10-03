# vorssaint (https://github.com/vorssaint/vorssaint-utils)
# The vorssaint installer adds this line to ~/.zprofile to put Homebrew on
# PATH for login shells. It's kept here so it survives re-installs; guarded so
# it's a no-op on machines without Apple Silicon Homebrew (Intel, Linux).
if [ -x /opt/homebrew/bin/brew ]; then
	eval "$(/opt/homebrew/bin/brew shellenv)"
fi
