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

_satin_prepare_prompt() {
  builtin emulate -L zsh
  builtin local ready_marker=$'\e]133;B\e\\'
  builtin print -nr -- $'\e]133;A\e\\'
  if [[ $PS1 != *$ready_marker* ]]; then
    PS1+="%{$ready_marker%}"
  fi
}
precmd_functions=(${precmd_functions:#_satin_prepare_prompt} _satin_prepare_prompt)

if [[ -x ${SATIN_NVIM_LAUNCHER:-} ]]; then
  unalias nvim 2>/dev/null || true
  unfunction nvim 2>/dev/null || true
  function nvim() {
    command "$SATIN_NVIM_LAUNCHER" "$@"
  }
fi

_satin_codex_definition=$(builtin whence -w codex 2>/dev/null)
_satin_codex_executable=${commands[codex]:-}
if [[ $_satin_codex_definition == 'codex: command' \
      && -n $_satin_codex_executable \
      && -x ${SATIN_CLI:-} \
      && ${SATIN_DISABLE_AGENT_INTEGRATION:-0} != 1 ]]; then
  function codex() {
    builtin emulate -L zsh
    "$SATIN_CLI" status session-start codex >/dev/null 2>&1 || true
    command "$_satin_codex_executable" "$@"
  }
else
  unset _satin_codex_executable
fi
unset _satin_codex_definition

_satin_claude_definition=$(builtin whence -w claude 2>/dev/null)
_satin_claude_executable=${commands[claude]:-}
if [[ $_satin_claude_definition == 'claude: command' \
      && -n $_satin_claude_executable \
      && -x ${SATIN_CLI:-} \
      && -r ${SATIN_CLAUDE_SETTINGS:-} \
      && ${SATIN_DISABLE_AGENT_INTEGRATION:-0} != 1 ]]; then
  function claude() {
    builtin emulate -L zsh
    builtin local argument
    "$SATIN_CLI" status session-start claude >/dev/null 2>&1 || true
    for argument in "$@"; do
      if [[ $argument == --settings || $argument == --settings=* ]]; then
        command "$_satin_claude_executable" "$@"
        return $?
      fi
    done
    command "$_satin_claude_executable" --settings "$SATIN_CLAUDE_SETTINGS" "$@"
  }
else
  unset _satin_claude_executable
fi
unset _satin_claude_definition
unset _satin_integration_zdotdir _satin_user_zdotdir
