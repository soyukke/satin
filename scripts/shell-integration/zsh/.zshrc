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
if [[ -x ${SATIN_NVIM_LAUNCHER:-} ]]; then
  unalias nvim 2>/dev/null || true
  unfunction nvim 2>/dev/null || true
  function nvim() {
    command "$SATIN_NVIM_LAUNCHER" "$@"
  }
fi
unset _satin_integration_zdotdir _satin_user_zdotdir
