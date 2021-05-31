#!/bin/zsh

cp -f /workspaces/.codespaces/.persistedshare/dotfiles/.* ~/
chsh -s /usr/bin/zsh $USERNAME

source ~/.zsrc
