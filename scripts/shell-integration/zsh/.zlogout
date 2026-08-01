_satin_user_zdotdir=${SATIN_USER_ZDOTDIR:-$HOME}
if [[ $_satin_user_zdotdir != $ZDOTDIR && -r $_satin_user_zdotdir/.zlogout ]]; then
  _satin_integration_zdotdir=$ZDOTDIR
  export ZDOTDIR=$_satin_user_zdotdir
  source "$_satin_user_zdotdir/.zlogout"
  export ZDOTDIR=$_satin_integration_zdotdir
fi
unset _satin_integration_zdotdir _satin_user_zdotdir
