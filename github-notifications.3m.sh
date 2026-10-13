#!/bin/bash

export SWIFTBAR_PLUGIN_PATH="${SWIFTBAR_PLUGIN_PATH:-$0}"

if output=$(npx --yes github-notifications-swiftbar@latest "$@" 2>/dev/null); then
  [[ -z "$output" ]] || printf '%s\n' "$output"
elif [[ $# -eq 0 ]]; then
  printf '%s\n' 'GitHub unavailable | color=red' '---' 'Could not start the plugin.'
else
  echo 'Could not start the plugin.' >&2
  exit 1
fi
