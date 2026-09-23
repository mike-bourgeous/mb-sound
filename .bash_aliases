# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# MB 2022-07 https://github.com/jonas/tig/issues/1011#issuecomment-736938541
# Make sure git completions are loaded before loading the aliases file
COMPLETION_DIR=$(pkg-config --variable=completionsdir bash-completion)
if [ -f "$COMPLETION_DIR/git" ]; then
	. "$COMPLETION_DIR/git"
fi


alias gs='git status'
alias gss='git status -s'
alias ga='git add -p'
alias gad='git add -A'
alias gc='git commit'
alias gd='git diff'
alias gdc='git diff --cached'
alias gb='git branch'
alias gl='git log'
alias gls='git log --stat'
alias gpsh='git push'
alias gpsha='git push --all; git push --tags'
alias gpll='git fetch -p && git pull'
alias gsh='git show'
alias gbl='git blame'
alias gco='git checkout'
alias gt='git tag'
alias gla='git log --format="%C(yellow)%h %<|(20)%Cgreen%an%x09%Cblue%ci/%ai%x09%Creset%s"'
alias gsa='git show --format="%C(yellow)%h %<|(20)%Cgreen%an%x09%Cblue%ci/%ai%x09%Creset%s"'

__git_complete gs _git_status
__git_complete gss _git_status
__git_complete ga _git_add
__git_complete gad _git_add
__git_complete gc _git_commit
__git_complete gd _git_diff
__git_complete gdc _git_diff
__git_complete gb _git_branch
__git_complete gl _git_log
__git_complete gls _git_log
__git_complete gpsh _git_push
__git_complete gpll _git_pull
__git_complete gsh _git_show
#__git_complete gbl _git_blame
__git_complete gbl _git_log
__git_complete gco _git_checkout
__git_complete gt _git_tag
__git_complete gla _git_log
__git_complete gsa _git_show


alias rhts="ruby -rwebrick -e'trap(:INT){Process.kill(9, 0)};WEBrick::HTTPServer.new(:Port => 8001, :DocumentRoot => Dir.pwd).start'"

cdgem()
{
	cd "$(bundle exec gem open "$1" -e echo)"
}

alias ls='ls --color'
