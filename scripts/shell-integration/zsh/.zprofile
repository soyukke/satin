_satin_integration_zdotdir=$ZDOTDIR
_satin_user_zdotdir=${SATIN_USER_ZDOTDIR:-$HOME}
if [[ $_satin_user_zdotdir != $_satin_integration_zdotdir \
      && -r $_satin_user_zdotdir/.zprofile ]]; then
  export ZDOTDIR=$_satin_user_zdotdir
  source "$_satin_user_zdotdir/.zprofile"
  if [[ -n ${ZDOTDIR:-} ]]; then
    export SATIN_USER_ZDOTDIR=$ZDOTDIR
  fi
fi
export ZDOTDIR=$_satin_integration_zdotdir
unset _satin_integration_zdotdir _satin_user_zdotdir
