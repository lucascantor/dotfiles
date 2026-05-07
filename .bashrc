#!/usr/bin/bash

# Fallback for environments where `chsh -s zsh` isn't possible: hand off interactive bash to zsh.
if [ -t 0 ] && command -v zsh > /dev/null 2>&1; then
	clear
	exec zsh
fi
