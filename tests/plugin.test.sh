#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/swiftbar-github-test.XXXXXX")
trap 'rm -rf "$temp"' EXIT
export HOME=$temp/home PATH=$temp/bin:$PATH
export SWIFTBAR_PLUGIN_PATH='/plugins/GitHub reviews.3m.sh'
export SWIFTBAR_PLUGIN_CACHE_PATH=$temp/cache SWIFTBAR_PLUGIN_DATA_PATH=$temp/data
export FIXTURES=$temp/fixtures EVENTS=$temp/events
export NOTIFIER_ARGS=$temp/notifier-args
mkdir -p "$HOME" "$temp/bin" "$FIXTURES"

cat > "$temp/bin/gh" <<'SH'
#!/bin/bash
set -eu
[[ ${FAIL_API:-} != 1 ]] || { echo 'secret-token' >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    user|search/issues|notifications) cat "$FIXTURES/${arg//\//-}.json"; exit 0 ;;
    notifications/threads/*) printf 'read %s\n' "${arg##*/}" >> "$EVENTS"; exit 0 ;;
  esac
done
exit 1
SH
cat > "$temp/bin/open" <<'SH'
#!/bin/bash
printf 'open %s %s\n' "$1" "$2" >> "$EVENTS"
[[ "$2" != "${FAIL_OPEN:-}" ]]
SH
cat > "$temp/bin/terminal-notifier" <<'SH'
#!/bin/bash
[[ ${FAIL_NOTIFY:-} != 1 ]] || exit 1
printf '%s\n' "$@" > "$NOTIFIER_ARGS"
printf 'notify\n' >> "$EVENTS"
SH
chmod +x "$temp/bin/gh" "$temp/bin/open" "$temp/bin/terminal-notifier"
printf '{"login":"reviewer"}\n' > "$FIXTURES/user.json"

reviews() {
  jq -n --argjson numbers "$1" '[{total_count: ($numbers | length), incomplete_results: false,
    items: [$numbers[] | {number: ., title: "Review \(.)",
      html_url: "https://github.com/example/repo/pull/\(.)",
      repository_url: "https://api.github.com/repos/example/repo"}]}]' > "$FIXTURES/search-issues.json"
}
notifications() {
  jq -n "[$1]" > "$FIXTURES/notifications.json"
}
run() {
  : > "$EVENTS"
  bash "$root/plugin.sh" "$@" > "$temp/menu" 2> "$temp/errors"
  [[ ! -s "$temp/errors" ]] || { cat "$temp/errors" >&2; exit 1; }
  [[ $(grep -c '^notify$' "$EVENTS" || true) == "${EXPECTED_ALERTS:-0}" ]]
}
contains() { grep -Fq -- "$1" "$2" || { printf 'Missing: %s\n' "$1" >&2; cat "$2" >&2; exit 1; }; }
absent() { if grep -Fq -- "$1" "$2"; then printf 'Unexpected: %s\n' "$1" >&2; exit 1; fi; }

notifications '[]'
reviews '[1]'
run
[[ ! -s "$EVENTS" ]]
contains 'in background: Off' "$temp/menu"
contains 'bash="/plugins/GitHub reviews.3m.sh" param1=toggle-auto-open terminal=false refresh=true' "$temp/menu"
run toggle-auto-open
[[ ! -s "$EVENTS" && ! -s "$temp/menu" ]]
run
contains 'in background: On' "$temp/menu"
[[ ! -s "$EVENTS" ]]
reviews '[1,2]'
EXPECTED_ALERTS=1 run
contains 'open -g https://github.com/example/repo/pull/2' "$EVENTS"
contains 'notify' "$EVENTS"
[[ $(grep -c '^open ' "$EVENTS") == 1 ]]
run
[[ ! -s "$EVENTS" ]]
run toggle-auto-open
reviews '[1,2,3]'
EXPECTED_ALERTS=1 run
absent 'open ' "$EVENTS"
run toggle-auto-open
run
[[ ! -s "$EVENTS" ]]

reviews '[1,2,3,4,5]'
export FAIL_OPEN=https://github.com/example/repo/pull/5
run
contains 'Could not open review request.' "$temp/menu"
unset FAIL_OPEN
EXPECTED_ALERTS=2 run
contains 'open -g https://github.com/example/repo/pull/5' "$EVENTS"
absent 'open -g https://github.com/example/repo/pull/4' "$EVENTS"

rm "$SWIFTBAR_PLUGIN_CACHE_PATH/opened-prs"
run
[[ ! -s "$EVENTS" ]]
reviews '[]'
run
[[ ! -s "$temp/menu" ]]
rm "$SWIFTBAR_PLUGIN_CACHE_PATH/requested-prs" "$SWIFTBAR_PLUGIN_CACHE_PATH/opened-prs"
reviews '[6]'
run
[[ ! -s "$EVENTS" ]]

notifications '[
  {id:"10", updated_at:"today", reason:"review_requested", repository:{full_name:"example/repo"}, subject:{type:"PullRequest", title:"Review 6", url:"https://api.github.com/repos/example/repo/pulls/6"}},
  {id:"11", updated_at:"today", reason:"mention", repository:{full_name:"example/repo"}, subject:{type:"Issue", title:"Title|with\ncontrols", url:"https://api.github.com/repos/example/repo/issues/9"}}
]'
EXPECTED_ALERTS=1 run
contains 'Notifications (1)' "$temp/menu"
contains 'example/repo [mention]: Title with controls | href=https://github.com/example/repo/issues/9' "$temp/menu"
contains 'param1=mark-read param2=10,11' "$temp/menu"
contains '--Pull requests (1)' "$temp/menu"
contains '--review requested (1)' "$temp/menu"
[[ $(grep -c '^notify$' "$EVENTS") == 1 ]]
run
[[ ! -s "$EVENTS" ]]
run open-notifications
contains 'open -g https://github.com/example/repo/issues/9' "$EVENTS"
absent 'notify' "$EVENTS"
run open-reviews
contains 'open -g https://github.com/example/repo/pull/6' "$EVENTS"
absent 'notify' "$EVENTS"
run mark-read 10,11
contains 'read 10' "$EVENTS"
contains 'read 11' "$EVENTS"
if bash "$root/plugin.sh" mark-read '10,0' > "$temp/menu" 2> "$temp/errors"; then exit 1; fi
contains 'Invalid notification thread ID.' "$temp/errors"

reviews '[6,7]'
jq '.[0].items[1].title = "[WIP] Review"' "$FIXTURES/search-issues.json" > "$temp/search"
mv "$temp/search" "$FIXTURES/search-issues.json"
export FAIL_NOTIFY=1
run
contains 'open -g https://github.com/example/repo/pull/7' "$EVENTS"
unset FAIL_NOTIFY
EXPECTED_ALERTS=1 run
absent 'open ' "$EVENTS"
contains '#7 [WIP] Review' "$NOTIFIER_ARGS"
run
[[ ! -s "$EVENTS" ]]
jq '.[0][1].subject.title = "[WIP] Issue" | .[0][1].updated_at = "tomorrow"' "$FIXTURES/notifications.json" > "$temp/notifications"
mv "$temp/notifications" "$FIXTURES/notifications.json"
EXPECTED_ALERTS=1 run
contains '\[WIP] Issue' "$NOTIFIER_ARGS"

export FAIL_API=1
run
contains 'GitHub request failed.' "$temp/menu"
absent 'secret-token' "$temp/menu"
if bash "$root/plugin.sh" open-reviews > "$temp/menu" 2> "$temp/errors"; then exit 1; fi
contains 'GitHub request failed.' "$temp/errors"
absent 'secret-token' "$temp/errors"
unset FAIL_API
jq '.[0].incomplete_results = true' "$FIXTURES/search-issues.json" > "$temp/search"
mv "$temp/search" "$FIXTURES/search-issues.json"
run
contains 'incomplete review search results' "$temp/menu"
reviews '[6]'
jq '.[0].total_count = 1001' "$FIXTURES/search-issues.json" > "$temp/search"
mv "$temp/search" "$FIXTURES/search-issues.json"
run
contains 'More than 1,000 review requests matched' "$temp/menu"
reviews '[6]'
cp "$SWIFTBAR_PLUGIN_CACHE_PATH/requested-prs" "$temp/previous-reviews"
jq '.[0].items[0].html_url = "https://example.com/pull/6"' "$FIXTURES/search-issues.json" > "$temp/search"
mv "$temp/search" "$FIXTURES/search-issues.json"
if bash "$root/plugin.sh" open-reviews > "$temp/menu" 2> "$temp/errors"; then exit 1; fi
cmp "$temp/previous-reviews" "$SWIFTBAR_PLUGIN_CACHE_PATH/requested-prs"
absent 'open ' "$EVENTS"
printf 'plugin tests passed\n'
