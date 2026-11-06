#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

mise_shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
export PATH="$mise_shims${PATH:+:$PATH}:/opt/homebrew/bin:/usr/local/bin"
export SWIFTBAR_GITHUB_DEV=1

if [[ -z ${SWIFTBAR_PLUGIN_PATH:-} ]]; then
  export SWIFTBAR_PLUGIN_PATH="$0"
fi

if [[ $# -eq 0 ]]; then
  is_menu=1
else
  is_menu=0
fi

report_error() {
  if [[ $is_menu -eq 1 ]]; then
    printf '%s\n' 'GitHub unavailable | color=red' '---' "$1"
    exit 0
  fi

  printf '%s\n' "$1" >&2
  exit 1
}

script=$0
link_count=0
while [[ -L $script ]]; do
  if (( link_count >= 40 )); then
    report_error 'Could not resolve the development launcher symlink.'
  fi
  ((link_count += 1))

  case $script in
    */*) script_directory=${script%/*} ;;
    *) script_directory=. ;;
  esac
  [[ -n $script_directory ]] || script_directory=/
  script_directory=$(cd -P -- "$script_directory" >/dev/null 2>&1 && pwd) ||
    report_error 'Could not resolve the development launcher directory.'
  target=$(readlink "$script" 2>/dev/null) ||
    report_error 'Could not read the development launcher symlink.'

  if [[ $target == /* ]]; then
    script=$target
  else
    script="$script_directory/$target"
  fi
done

case $script in
  */*) script_directory=${script%/*} ;;
  *) script_directory=. ;;
esac
[[ -n $script_directory ]] || script_directory=/
script_directory=$(cd -P -- "$script_directory" >/dev/null 2>&1 && pwd) ||
  report_error 'Could not resolve the development launcher directory.'
plugin_file="$script_directory/plugin.sh"

if [[ ! -f $plugin_file ]]; then
  report_error 'Local plugin.sh not found beside the development launcher.'
fi

exec "$BASH" "$plugin_file" "$@"
