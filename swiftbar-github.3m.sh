#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

mise_shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
export PATH="$mise_shims${PATH:+:$PATH}:/opt/homebrew/bin:/usr/local/bin"

if [[ -z ${SWIFTBAR_PLUGIN_PATH:-} ]]; then
  export SWIFTBAR_PLUGIN_PATH="$0"
fi

plugin_basename=${SWIFTBAR_PLUGIN_PATH##*/}
[[ -n $plugin_basename ]] || plugin_basename=${0##*/}
plugin_data_path=${SWIFTBAR_PLUGIN_DATA_PATH:-"$HOME/.local/share/swiftbar/$plugin_basename"}
plugin_file="$plugin_data_path/plugin.sh"
tag_file="$plugin_data_path/plugin-version"
check_file="$plugin_data_path/last-update-check"
update_interval=86400

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

is_stable_tag() {
  [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_is_greater() {
  jq -en --arg candidate "$1" --arg current "$2" '
    def version: ltrimstr("v") | split(".") | map(tonumber);
    ($candidate | version) > ($current | version)
  ' >/dev/null 2>&1
}

get_latest_stable_tag() {
  local tags latest

  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if ! tags=$(gh api --hostname github.com repos/jryom/swiftbar-github/tags --paginate --jq '.[].name' 2>/dev/null); then
    return 1
  fi

  latest=$(printf '%s\n' "$tags" | jq -Rsr '
    split("\n") | map(select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))) |
    sort_by(ltrimstr("v") | split(".") | map(tonumber)) | last // empty
  ' 2>/dev/null) || return 1

  [[ -n $latest ]] || return 2
  printf '%s\n' "$latest"
}

atomic_write() {
  local destination=$1
  local content=$2
  local temporary

  temporary=$(mktemp "${destination}.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$temporary"; then
    rm -f "$temporary" >/dev/null 2>&1
    return 1
  fi
  if ! mv -f "$temporary" "$destination" >/dev/null 2>&1; then
    rm -f "$temporary" >/dev/null 2>&1
    return 1
  fi
}

download_plugin() {
  local tag=$1
  local temporary
  local url

  is_stable_tag "$tag" || return 1
  temporary=$(mktemp "$plugin_data_path/.plugin.sh.XXXXXX" 2>/dev/null) || return 1
  url="https://raw.githubusercontent.com/jryom/swiftbar-github/$tag/plugin.sh"

  if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 --output "$temporary" "$url" 2>/dev/null; then
    rm -f "$temporary" >/dev/null 2>&1
    return 1
  fi
  if [[ $(head -n 1 "$temporary") != '#!/bin/bash' ]] || ! "$BASH" -n "$temporary" >/dev/null 2>&1; then
    rm -f "$temporary" >/dev/null 2>&1
    return 1
  fi
  if ! mv -f "$temporary" "$plugin_file" >/dev/null 2>&1; then
    rm -f "$temporary" >/dev/null 2>&1
    return 1
  fi

  atomic_write "$tag_file" "$tag" || true
}

read_cached_tag() {
  cached_tag=
  if [[ -r $tag_file ]]; then
    IFS= read -r cached_tag < "$tag_file"
  fi
  is_stable_tag "$cached_tag" || cached_tag=
}

update_check_is_due() {
  local checked_at
  local now
  local checked_epoch
  local now_epoch

  [[ -r $check_file ]] || return 0
  IFS= read -r checked_at < "$check_file" || return 0
  [[ $checked_at =~ ^[0-9]{1,12}$ ]] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  [[ $now =~ ^[0-9]{1,12}$ ]] || return 0

  checked_epoch=$((10#$checked_at))
  now_epoch=$((10#$now))
  (( checked_epoch > now_epoch )) && return 0
  (( now_epoch - checked_epoch >= update_interval ))
}

record_update_check() {
  local now

  now=$(date +%s 2>/dev/null) || return 1
  [[ $now =~ ^[0-9]{1,12}$ ]] || return 1
  atomic_write "$check_file" "$now"
}

cache_is_valid=0
if [[ -s $plugin_file ]] && "$BASH" -n "$plugin_file" >/dev/null 2>&1; then
  cache_is_valid=1
fi

if [[ $cache_is_valid -eq 1 ]]; then
  if [[ $is_menu -eq 1 ]] && update_check_is_due; then
    record_update_check >/dev/null 2>&1 || true
    if latest_tag=$(get_latest_stable_tag); then
      read_cached_tag
      if { [[ -z $cached_tag ]] || version_is_greater "$latest_tag" "$cached_tag"; } && download_plugin "$latest_tag"; then
        cached_tag=$latest_tag
      fi
    fi
  fi

  exec "$BASH" "$plugin_file" "$@"
fi

if ! command -v gh >/dev/null 2>&1; then
  report_error "GitHub CLI (gh) not found. Add gh to SwiftBar's PATH."
fi
if ! command -v jq >/dev/null 2>&1; then
  report_error "jq not found. Add jq to SwiftBar's PATH."
fi
if ! command -v curl >/dev/null 2>&1; then
  report_error "curl not found. Add curl to SwiftBar's PATH."
fi
if ! mkdir -p "$plugin_data_path" 2>/dev/null; then
  report_error 'Could not create the plugin cache. Check its permissions and try again.'
fi

if latest_tag=$(get_latest_stable_tag); then
  :
else
  tag_status=$?
  if [[ $tag_status -eq 2 ]]; then
    report_error 'No stable plugin version is available yet.'
  fi
  report_error 'Could not check GitHub for a plugin version. Check your connection and try again.'
fi

if ! download_plugin "$latest_tag"; then
  report_error 'Could not download a valid plugin version. Check your connection and try again.'
fi
record_update_check >/dev/null 2>&1 || true

exec "$BASH" "$plugin_file" "$@"
