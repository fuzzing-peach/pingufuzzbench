# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export http_proxy="http://172.17.0.1:7890"
export https_proxy="http://172.17.0.1:7890"

# Lines configured by zsh-newuser-install
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000
bindkey -v
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '/home/ubuntu/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

autoload -U +X bashcompinit && bashcompinit

### Added by Zinit's installer
if [[ ! -f $HOME/.local/share/zinit/zinit.git/zinit.zsh ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
    command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git" && \
        print -P "%F{33} %F{34}Installation successful.%f%b" || \
        print -P "%F{160} The clone has failed.%f%b"
fi

source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

# Load a few important annexes, without Turbo
# (this is currently required for annexes)
zinit light-mode for \
    zdharma-continuum/zinit-annex-as-monitor \
    zdharma-continuum/zinit-annex-bin-gem-node \
    zdharma-continuum/zinit-annex-patch-dl \
    zdharma-continuum/zinit-annex-rust

### End of Zinit's installer chunk

zinit ice depth=1; zinit light romkatv/powerlevel10k

zinit light-mode wait lucid depth=1 for \
 atinit"ZINIT[COMPINIT_OPTS]=-C; zpcompinit; zpcdreplay" \
    zdharma-continuum/fast-syntax-highlighting \
 atload"!_zsh_autosuggest_start" \
    zsh-users/zsh-autosuggestions \
 blockf \
    zsh-users/zsh-completions

# bindkey '     ' autosuggest-accept

zinit ice wait lucid atload"bindkey '^a' history-substring-search-up; bindkey '^b' history-substring-search-down"
zinit light zsh-users/zsh-history-substring-search

zinit light Aloxaf/fzf-tab

# zsh-fzf-history-search
zinit ice lucid wait'0'
zinit light joshskidmore/zsh-fzf-history-search

# zsh completetions for cargo
zinit ice lucid nocompile
zinit load MenkeTechnologies/zsh-cargo-completion

# you-should-use
zinit ice wait lucid depth=1; zinit light MichaelAquilina/zsh-you-should-use
export YSU_MESSAGE_POSITION="after"

zinit ice as"completion"
zinit snippet https://github.com/watchexec/cargo-watch/tree/8.x/completions/zsh

# oh-my-zsh libs
zi light-mode lucid for \
    OMZ::lib/git.zsh \
    OMZ::lib/grep.zsh \
    OMZ::lib/history.zsh \
    OMZ::lib/functions.zsh \
    OMZ::lib/completion.zsh \
    OMZ::lib/directories.zsh \
    OMZ::lib/key-bindings.zsh \
    OMZ::lib/theme-and-appearance.zsh

# oh-my-zsh plugins
zi light-mode wait lucid for \
    OMZ::plugins/git/git.plugin.zsh \
    OMZ::plugins/pip/pip.plugin.zsh \
    OMZ::plugins/extract/extract.plugin.zsh \
    OMZ::plugins/sudo/sudo.plugin.zsh \
    OMZ::plugins/python/python.plugin.zsh \
    OMZ::plugins/history/history.plugin.zsh \
    OMZ::plugins/autojump/autojump.plugin.zsh \
    OMZ::plugins/gitignore/gitignore.plugin.zsh \
    OMZ::plugins/common-aliases/common-aliases.plugin.zsh

[[ -s /home/ubuntu/.autojump/etc/profile.d/autojump.sh ]] && source /home/ubuntu/.autojump/etc/profile.d/autojump.sh

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

export CARGO_HOME=/home/ubuntu/.cargo
# export CMAKE_HOME=/home/ubuntu/cmake-3.29.3-linux-x86_64
export RUSTUP_HOME=/home/ubuntu/.rustup

export PATH=$CARGO_HOME/bin:$PATH

alias cb="cargo build"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
