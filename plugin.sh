#!/bin/bash
set -Eeuo pipefail
umask 077

export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH:/opt/homebrew/bin:/usr/local/bin"
export GH_PROMPT_DISABLED=1
inbox=https://github.com/notifications
launcher=${SWIFTBAR_PLUGIN_PATH:-$0}
cache=${SWIFTBAR_PLUGIN_CACHE_PATH:-$HOME/.cache/swiftbar/$(basename "$launcher")}
data=${SWIFTBAR_PLUGIN_DATA_PATH:-$HOME/.local/share/swiftbar/$(basename "$launcher")}
setting=$data/auto-open-reviews
argument=${1:-}
icon=$(printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path transform="translate(4 4)" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>' | base64 | tr -d '\n')

fail() {
  trap - ERR
  if [[ -n "$argument" ]]; then
    printf '%s\n' "$1" >&2
    exit 1
  fi
  printf '? | color=red templateImage=%s href=%s\n---\n%s\n' "$icon" "$inbox" "$1"
  exit 0
}
trap 'fail "Could not retrieve GitHub activity. Check your connection and GitHub login."' ERR

for tool in gh jq terminal-notifier; do
  command -v "$tool" >/dev/null || fail "Missing $tool. Install it with brew install $tool."
done

mkdir -p "$cache" "$data"
work=$(mktemp -d "$cache/run.XXXXXX")
trap 'rm -f "$work"/*; rmdir "$work"' EXIT

save() {
  local target=$1 source=$2
  cp "$source" "$target.$$"
  mv -f "$target.$$" "$target"
}

case "$argument" in
  toggle-auto-open)
    if [[ -s "$setting" ]]; then : > "$work/setting"; else printf 'enabled\n' > "$work/setting"; fi
    save "$setting" "$work/setting"
    exit 0
    ;;
  mark-read)
    [[ ${2:-} =~ ^[0-9]+(,[0-9]+)*$ ]] || fail 'Usage: plugin.sh mark-read <thread-ids>'
    IFS=, read -r -a ids <<< "$2"
    for id in "${ids[@]}"; do
      [[ $id =~ ^[1-9][0-9]*$ ]] || fail 'Invalid notification thread ID.'
    done
    for id in "${ids[@]}"; do
      gh api --hostname github.com --method PATCH "notifications/threads/$id" --silent 2>/dev/null || fail 'Could not mark notifications as read.'
    done
    exit 0
    ;;
  ''|open-reviews|open-notifications) ;;
  *) fail 'Usage: plugin.sh [open-reviews|open-notifications|mark-read|toggle-auto-open]' ;;
esac

api() {
  local output=$1
  shift
  gh api --hostname github.com "$@" > "$output" 2>/dev/null || fail 'GitHub request failed. Check gh auth login, token permissions, and rate limits.'
}

api "$work/user" user
login=$(jq -er '.login | select(test("^[a-zA-Z0-9-]+$"))' "$work/user") || fail 'GitHub returned invalid user data.'
api "$work/search" search/issues --method GET --paginate --slurp -f "q=is:pr is:open archived:false review-requested:$login" -f per_page=100
jq -e 'length > 0 and all(.[]; .incomplete_results == false and (.total_count | type == "number"))' "$work/search" >/dev/null || fail 'GitHub returned incomplete review search results.'
jq -e 'all(.[]; .total_count <= 1000)' "$work/search" >/dev/null || fail 'More than 1,000 review requests matched. GitHub search cannot return all of them.'

filters='
def clean: if type == "string" then gsub("[|\r\n\t]"; " ") else error("Invalid GitHub data") end;
def web_url:
  if .subject.type == "Release" then .repository.html_url + "/releases"
  elif (.subject.type | IN("PullRequest", "Issue", "Discussion", "Commit")) and
    ((.subject.url // "") | startswith("https://api.github.com/repos/")) then
    .subject.url | sub("https://api.github.com/repos/"; "https://github.com/") |
    sub("/pulls/"; "/pull/") | sub("/commits/"; "/commit/")
  else "https://github.com/notifications" end;
def safe_url: if test("^https://github\\.com/[^|\\s]+$") then . else error("Invalid GitHub URL") end;
'
jq "$filters"'
  [.[].items[] | {
    url: (.html_url | safe_url), key: (.html_url | safe_url),
    repository: (.repository_url | sub("^https://api.github.com/repos/"; "") | clean),
    title: ("#\(.number) " + (.title | clean)), alertTitle: "Review requested"
  }] | unique_by(.key)
' "$work/search" > "$work/reviews"

if [[ "$argument" == open-reviews ]]; then
  while IFS= read -r url; do open -g "$url" 2>/dev/null || fail 'Could not open review request.'; done < <(jq -r '.[].url' "$work/reviews")
  exit 0
fi

api "$work/pages" notifications --method GET --paginate --slurp -f all=false -f participating=false -f per_page=50
jq 'add // []' "$work/pages" > "$work/unread"
jq --slurpfile reviews "$work/reviews" "$filters"'
  [$reviews[0][].url] as $urls |
  [ .[] | . + {web: (web_url | safe_url)} |
    select(.reason != "review_requested" or (.web as $url | $urls | index($url) | not)) |
    {key: (.id + ":" + .updated_at), repository: (.repository.full_name | clean),
     title: (.subject.title | clean), url: .web, reason: (.reason | clean | gsub("_"; " ")),
     alertTitle: ("GitHub: " + (.reason | clean | gsub("_"; " ")))}
  ]
' "$work/unread" > "$work/notifications"

if [[ "$argument" == open-notifications ]]; then
  while IFS= read -r url; do open -g "$url" 2>/dev/null || fail 'Could not open notification.'; done < <(jq -r '.[].url' "$work/notifications")
  exit 0
fi

auto_open=Off
[[ ! -s "$setting" ]] || auto_open=On
previous_opened=$cache/opened-prs
[[ -f "$previous_opened" ]] || previous_opened=$cache/requested-prs
if [[ "$auto_open" == On && -f "$previous_opened" ]]; then
  cp "$previous_opened" "$work/opened"
  while IFS= read -r url; do
    if ! grep -Fqx -- "$url" "$work/opened"; then
      open -g "$url" 2>/dev/null || fail 'Could not open review request.'
      printf '%s\n' "$url" >> "$work/opened"
      save "$cache/opened-prs" "$work/opened"
    fi
  done < <(jq -r '.[].url' "$work/reviews")
fi
jq -r '.[].key' "$work/reviews" > "$work/opened"
save "$cache/opened-prs" "$work/opened"

cat "$work/opened" > "$work/review-urls"
[[ ! -f "$cache/requested-prs" ]] || cat "$cache/requested-prs" >> "$work/review-urls"
jq -Rn '[inputs]' < "$work/review-urls" > "$work/represented-urls"
jq --slurpfile urls "$work/represented-urls" "$filters"'
  .[] | select(.reason == "review_requested" and (web_url as $url | $urls[0] | index($url))) |
  .id + ":" + .updated_at
' "$work/unread" > "$work/represented"

notification_text() {
  case "$1" in
    -*) printf ' %s' "$1" ;;
    '['*|'('*|'{'*|'"'*|"'"*|' '*|\\*) printf '\\%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

alerts() {
  local file=$1 items=$2 represented=$3 key url repository title alert_title
  cp "$represented" "$work/current"
  while IFS=$'\t' read -r key url repository title alert_title; do
    grep -Fqx -- "$key" "$work/current" && continue
    if [[ -f "$file" ]] && ! grep -Fqx -- "$key" "$file"; then
      if ! terminal-notifier -title "$alert_title" -subtitle "$repository" -message "$(notification_text "$title")" \
        -open "$url" -group "github-$url" -sound default >/dev/null 2>&1; then
        continue
      fi
    fi
    printf '%s\n' "$key" >> "$work/current"
  done < <(jq -r '.[] | [.key, .url, .repository, .title, .alertTitle] | join("\t")' "$items")
  save "$file" "$work/current"
}
: > "$work/empty"
alerts "$cache/requested-prs" "$work/reviews" "$work/empty"
alerts "$cache/inbox-notifications" "$work/notifications" "$work/represented"

action() {
  local label=$1 refresh=$2 arg index=1
  shift 2
  printf '%s | bash="%s"' "$label" "${launcher//\"/\\\"}"
  for arg in "$@"; do printf ' param%s=%s' "$index" "$arg"; index=$((index + 1)); done
  printf ' terminal=false'
  [[ "$refresh" != true ]] || printf ' refresh=true'
  printf '\n'
}

review_count=$(jq length "$work/reviews")
notification_count=$(jq length "$work/notifications")
total=$((review_count + notification_count))
[[ $total -gt 0 ]] || exit 0
prefix=''
[[ -z ${SWIFTBAR_GITHUB_DEV:-} ]] || prefix='Dev '
printf '%s%s | templateImage=%s\n---\nReview requests (%s) | color=gray\n' "$prefix" "$total" "$icon" "$review_count"
if [[ $review_count -gt 0 ]]; then
  jq -r '.[] | "\(.repository) \(.title) | href=\(.url) refresh=true"' "$work/reviews"
  action 'Open all review requests' true open-reviews
else
  printf 'No reviews requested | color=gray\n'
fi
printf '%s\n' '---' "Notifications ($notification_count) | color=gray"
if [[ $notification_count -gt 0 ]]; then
  jq -r '.[] | "\(.repository) [\(.reason)]: \(.title) | href=\(.url) refresh=true"' "$work/notifications"
  action 'Open all notifications' true open-notifications
else
  printf 'No unread notifications | color=gray\n'
fi
unread_count=$(jq length "$work/unread")
if [[ $unread_count -gt 0 ]]; then
  printf '%s\n' '---' 'Mark as read'
  printf -- '--'
  action "All notifications ($unread_count)" true mark-read "$(jq -r 'map(.id) | join(",")' "$work/unread")"
  for group in type reason; do
    if [[ "$group" == type ]]; then heading='By type'; else heading='By reason'; fi
    printf '%s\n' '-----' "--$heading | color=gray"
    while IFS=$'\t' read -r label ids; do
      printf -- '--'
      action "$label" true mark-read "$ids"
    done < <(jq -r --arg group "$group" "$filters"'
      {PullRequest: "Pull requests", Issue: "Issues", Discussion: "Discussions", Commit: "Commits", Release: "Releases"} as $types |
      map(. + {label: (if $group == "type" then ($types[.subject.type] // .subject.type) else (.reason | gsub("_"; " ")) end | clean)}) |
      group_by(.label)[] | ["\(.[0].label) (\(length))", (map(.id) | join(","))] | join("\t")
    ' "$work/unread")
  done
fi
printf '%s\n' '---'
action "Auto-open new review requests in background: $auto_open" true toggle-auto-open
