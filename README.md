# GitHub notifications for SwiftBar

A macOS menu bar plugin for unread GitHub notifications and pending review requests. Refreshes every three minutes and sends desktop alerts for new activity. Hidden when there is nothing pending; the first run is silent.

## Setup

Requires macOS, SwiftBar, and Node.js 24.15+ (24.x). `node` and `npx` must be on SwiftBar's `PATH`. To reuse your GitHub CLI login, `gh` must be there too:

```sh
brew install --cask swiftbar
brew install gh
gh auth login --hostname github.com
```

Save this as `github-notifications.3m.sh` in your SwiftBar plugin folder:

```bash
#!/bin/bash

if output=$(npx --yes github-notifications-swiftbar@latest "$@" 2>/dev/null); then
  [[ -z "$output" ]] || printf '%s\n' "$output"
elif [[ $# -eq 0 ]]; then
  printf '%s\n' 'GitHub unavailable | color=red' '---' 'Could not start the plugin.'
else
  echo 'Could not start the plugin.' >&2
  exit 1
fi
```

Run `chmod +x github-notifications.3m.sh`. Updates resolve through `@latest` on each refresh; downloaded versions are cached. For authentication without `gh`, set `GH_TOKEN` or `GITHUB_TOKEN` in SwiftBar's environment.

Allow notifications for the bundled terminal-notifier in macOS System Settings. Click entries to open them on GitHub.
