#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

if output=$(npx --yes swiftbar-github@latest "$@" 2>/dev/null); then
  [[ -z "$output" ]] || printf '%s\n' "$output"
elif [[ $# -eq 0 ]]; then
  printf '%s\n' 'GitHub unavailable | color=red' '---' 'Could not start the plugin.'
else
  echo 'Could not start the plugin.' >&2
  exit 1
fi
