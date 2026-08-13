_satin_integration_zdotdir=$ZDOTDIR
_satin_user_zdotdir=${SATIN_USER_ZDOTDIR:-$HOME}
if [[ $_satin_user_zdotdir != $_satin_integration_zdotdir \
      && -r $_satin_user_zdotdir/.zshrc ]]; then
  export ZDOTDIR=$_satin_user_zdotdir
  source "$_satin_user_zdotdir/.zshrc"
  if [[ -n ${ZDOTDIR:-} ]]; then
    export SATIN_USER_ZDOTDIR=$ZDOTDIR
  fi
fi
export ZDOTDIR=$_satin_integration_zdotdir

_satin_report_pwd() {
  builtin emulate -L zsh
  builtin local LC_ALL=C character encoded='' hex
  for character in ${(s::)PWD}; do
    if [[ $character == [A-Za-z0-9/._~-] ]]; then
      encoded+=$character
    else
      builtin printf -v hex '%02X' "'$character"
      encoded+="%$hex"
    fi
  done
  builtin print -nr -- $'\e]7;file://'"$encoded"$'\a'
}
builtin typeset -ga chpwd_functions precmd_functions
chpwd_functions=(${chpwd_functions:#_satin_report_pwd} _satin_report_pwd)
precmd_functions=(${precmd_functions:#_satin_report_pwd} _satin_report_pwd)
_satin_report_pwd

if [[ -x ${SATIN_NVIM_LAUNCHER:-} ]]; then
  unalias nvim 2>/dev/null || true
  unfunction nvim 2>/dev/null || true
  function nvim() {
    command "$SATIN_NVIM_LAUNCHER" "$@"
  }
fi
unset _satin_integration_zdotdir _satin_user_zdotdir
