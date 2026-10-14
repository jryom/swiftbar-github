# GitHub notifications for SwiftBar

A macOS menu bar plugin for unread GitHub notifications and pending review requests. Refreshes every three minutes and sends desktop alerts for new activity. Hidden when there is nothing pending; the first run is silent.

## Setup

Requires macOS, SwiftBar, and Node.js 24.15+ (24.x). `node` and `npx` must be on SwiftBar's `PATH`. To reuse your GitHub CLI login, `gh` must be there too:

```sh
brew install --cask swiftbar
brew install gh
gh auth login --hostname github.com
```

Download [github-notifications.3m.sh](https://cdn.jsdelivr.net/npm/github-notifications-swiftbar@latest/github-notifications.3m.sh) into your SwiftBar plugin folder.

Run `chmod +x github-notifications.3m.sh`. Updates resolve through `@latest` on each refresh; downloaded versions are cached. For authentication without `gh`, set `GH_TOKEN` or `GITHUB_TOKEN` in SwiftBar's environment.

Allow notifications for the bundled terminal-notifier in macOS System Settings. Click entries to open them on GitHub.
