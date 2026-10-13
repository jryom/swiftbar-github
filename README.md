# GitHub notifications for SwiftBar

A macOS menu bar plugin for unread GitHub notifications and pending review requests. Refreshes every three minutes and sends desktop alerts for new activity. Hidden when there is nothing pending; the first run is silent.

## Setup

Install SwiftBar, Node.js 24.15 or newer (24.x), and GitHub CLI. `node`, `npx`, and `gh` must be on SwiftBar's `PATH`, not just your terminal's. The plugin does not configure `PATH`. Sign in to GitHub from Terminal:

```sh
brew install --cask swiftbar
brew install gh
gh auth login --hostname github.com
```

Save this as `github-notifications.3m.sh` in your SwiftBar plugin folder:

```bash
#!/bin/bash
export SWIFTBAR_PLUGIN_PATH="${SWIFTBAR_PLUGIN_PATH:-$0}"
npx --yes github-notifications-swiftbar@latest "$@"
```

Make it executable with `chmod +x github-notifications.3m.sh`. The launcher resolves `@latest` on each refresh and caches downloaded versions. `gh` supplies your GitHub token; alternatively, set `GH_TOKEN` or `GITHUB_TOKEN` in SwiftBar's environment.

Allow desktop notifications for terminal-notifier in macOS System Settings. Click an entry to open it on GitHub. Review requests cover all repositories your account can access.
