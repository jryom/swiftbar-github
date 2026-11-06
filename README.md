# SwiftBar GitHub

A macOS menu bar plugin for unread GitHub notifications and pending review requests. Refreshes every three minutes and sends desktop alerts for new activity. Hidden when there is nothing pending; the first run is silent.

## Setup

Requires macOS, SwiftBar, `gh`, `jq`, and `terminal-notifier`. No Node.js, npm, or build step. The launcher adds mise shims and standard Homebrew locations to `PATH`.

```sh
brew install --cask swiftbar
brew install gh jq terminal-notifier
gh auth login --hostname github.com
```

In your SwiftBar plugin folder:

```sh
curl -fsSL https://raw.githubusercontent.com/jryom/swiftbar-github/main/swiftbar-github.3m.sh -o swiftbar-github.3m.sh
chmod +x swiftbar-github.3m.sh
```

The launcher downloads `plugin.sh` from a version tag and checks for updates daily. A failed download leaves the last working version in place. For token-based authentication, set `GH_TOKEN` or `GITHUB_TOKEN` in SwiftBar's environment.

Allow notifications for terminal-notifier in macOS System Settings. Click entries or desktop notifications to open them on GitHub.

Use **Mark as read** to clear unread threads by type or reason. This does not complete pending review requests. Option-click the menu to access SwiftBar's hidden controls.

Enable **Auto-open new review requests in background** in the plugin menu to open newly requested reviews in your default browser without bringing it forward. It is off by default and remembers your choice. Existing requests and the first run do not open tabs; desktop alerts still appear for new activity. Browser behavior may vary.

## Local development

Symlink `swiftbar-github-dev.3m.sh` from this checkout into your SwiftBar plugin folder. Edit `plugin.sh` and refresh SwiftBar; no build or publishing needed. Keep production disabled while testing to avoid duplicate alerts.

Run `bash tests/run.sh` for tests and shellcheck (install shellcheck for development). GitHub calls, notifications, and browser opens are mocked.

## Releases

Push a stable version tag such as `v2.0.0` to release the committed `plugin.sh`. No npm publishing or release artifacts are needed. Do not move existing version tags.
