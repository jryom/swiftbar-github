#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/swiftbar-github-launcher.XXXXXX")
trap 'rm -rf "$temp"' EXIT

export HOME="$temp/home"
export PATH="$temp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GH_LOG="$temp/gh.log"
export CURL_LOG="$temp/curl.log"
export PLUGIN_SOURCE="$temp/plugin-source.sh"
stdout_file="$temp/stdout"
stderr_file="$temp/stderr"
default_data="$HOME/.local/share/swiftbar/swiftbar-github.3m.sh"
cache_file="$default_data/plugin.sh"
tag_file="$default_data/plugin-version"
check_file="$default_data/last-update-check"

unset SWIFTBAR_PLUGIN_PATH SWIFTBAR_PLUGIN_DATA_PATH XDG_DATA_HOME
unset SWIFTBAR_GITHUB_DEV GH_FAIL CURL_FAIL CURL_INVALID PLUGIN_EMPTY_OUTPUT
mkdir -p "$temp/bin" "$HOME/.local/share/mise/shims"
: > "$GH_LOG"
: > "$CURL_LOG"

cat > "$temp/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [[ ${GH_FAIL:-0} == 1 ]]; then
  printf 'token=gh-secret\n' >&2
  exit 1
fi
printf '%s\n' "${GH_TAGS-}"
SH

cat > "$temp/bin/curl" <<'SH'
#!/bin/bash
output=
url=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output|-o) output=$2; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
if [[ ${CURL_FAIL:-0} == 1 ]]; then
  printf 'token=curl-secret\n' >&2
  exit 1
fi
if [[ ${CURL_INVALID:-0} == 1 ]]; then
  printf 'if (\n' > "$output"
else
  cp "$PLUGIN_SOURCE" "$output"
fi
SH

cat > "$temp/bin/missing-tool.sh" <<'SH'
command() {
  if [[ ${1:-} == -v && ${2:-} == "${MISSING_TOOL:-}" ]]; then
    return 1
  fi
  builtin command "$@"
}
SH

cat > "$temp/bin/mise-test-tool" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$temp/bin/path-test-tool" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$temp/bin/gh" "$temp/bin/curl" "$temp/bin/mise-test-tool" \
  "$temp/bin/path-test-tool"
cp "$temp/bin/mise-test-tool" "$HOME/.local/share/mise/shims/mise-test-tool"

write_plugin() {
  local version=$1
  cat > "$PLUGIN_SOURCE" <<SH
#!/bin/bash
if [[ \${PLUGIN_EMPTY_OUTPUT:-0} == 1 ]]; then exit 0; fi
printf 'version=$version path=%s dev=%s args=' "\${SWIFTBAR_PLUGIN_PATH-}" "\${SWIFTBAR_GITHUB_DEV-}"
for arg in "\$@"; do printf ' <%s>' "\$arg"; done
printf ' tools=%s,%s' "\$(command -v mise-test-tool || true)" "\$(command -v path-test-tool || true)"
printf '\\n'
SH
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -s $stdout_file ]]; then cat "$stdout_file" >&2; fi
  if [[ -s $stderr_file ]]; then cat "$stderr_file" >&2; fi
  exit 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  [[ $actual == "$expected" ]] || fail "expected [$expected], got [$actual]"
}

assert_stdout() {
  printf '%s' "$1" > "$temp/expected"
  cmp -s "$temp/expected" "$stdout_file" || fail "unexpected stdout"
}

assert_contains() {
  grep -Fq -- "$1" "$2" || fail "missing [$1] in $2"
}

assert_absent() {
  if grep -Fq -- "$1" "$2"; then fail "unexpected [$1] in $2"; fi
}

assert_no_stderr() {
  [[ ! -s $stderr_file ]] || fail "unexpected stderr"
}

line_count() {
  local count
  count=$(wc -l < "$1")
  count=${count//[[:space:]]/}
  printf '%s\n' "$count"
}

run_launcher() {
  local expected_status=$1
  local status
  shift

  if bash "$root/swiftbar-github.3m.sh" "$@" > "$stdout_file" 2> "$stderr_file"; then
    status=0
  else
    status=$?
  fi
  [[ $status -eq $expected_status ]] || fail "launcher exited $status, expected $expected_status"
}

run_with_missing_tool() {
  local missing_tool=$1
  local expected_status=$2
  local status
  shift 2

  if MISSING_TOOL=$missing_tool BASH_ENV="$temp/bin/missing-tool.sh" \
    bash "$root/swiftbar-github.3m.sh" "$@" > "$stdout_file" 2> "$stderr_file"; then
    status=0
  else
    status=$?
  fi
  [[ $status -eq $expected_status ]] || fail "launcher exited $status, expected $expected_status"
}

export GH_TAGS=$'v1.9.0\nv1.10.0\nv2.0.0-rc.1\nmain\nv999.0.0/../../main'
write_plugin one
run_launcher 0 open-reviews
expected_tools="$HOME/.local/share/mise/shims/mise-test-tool,$temp/bin/path-test-tool"
assert_stdout "version=one path=$root/swiftbar-github.3m.sh dev= args= <open-reviews> tools=$expected_tools"$'\n'
assert_no_stderr
assert_equal 'https://raw.githubusercontent.com/jryom/swiftbar-github/v1.10.0/plugin.sh' "$(head -n 1 "$CURL_LOG")"
assert_contains 'repos/jryom/swiftbar-github/tags' "$GH_LOG"
assert_equal 'v1.10.0' "$(cat "$tag_file")"
cmp -s "$PLUGIN_SOURCE" "$cache_file" || fail 'bootstrap cache differs from downloaded plugin'

export PLUGIN_EMPTY_OUTPUT=1
run_launcher 0 open-reviews
assert_stdout ''
unset PLUGIN_EMPTY_OUTPUT

gh_count=$(line_count "$GH_LOG")
curl_count=$(line_count "$CURL_LOG")
export GH_TAGS=v99.0.0
run_launcher 0 mark-read
assert_contains 'args= <mark-read>' "$stdout_file"
assert_equal "$gh_count" "$(line_count "$GH_LOG")"
assert_equal "$curl_count" "$(line_count "$CURL_LOG")"

custom_data="$temp/persistent-data"
custom_xdg="$temp/custom-xdg"
mkdir -p "$custom_xdg/mise/shims"
cp "$temp/bin/mise-test-tool" "$custom_xdg/mise/shims/mise-test-tool"
export SWIFTBAR_PLUGIN_PATH=/plugins/custom-github.3m.sh
export SWIFTBAR_PLUGIN_DATA_PATH=$custom_data XDG_DATA_HOME=$custom_xdg GH_TAGS=v1.0.0
run_launcher 0 toggle-auto-open
assert_contains 'path=/plugins/custom-github.3m.sh' "$stdout_file"
assert_contains "tools=$custom_xdg/mise/shims/mise-test-tool,$temp/bin/path-test-tool" "$stdout_file"
[[ -s $custom_data/plugin.sh ]] || fail 'plugin was not cached under SWIFTBAR_PLUGIN_DATA_PATH'
unset SWIFTBAR_PLUGIN_PATH SWIFTBAR_PLUGIN_DATA_PATH XDG_DATA_HOME

printf '0\n' > "$check_file"
write_plugin two
export GH_TAGS=$'v1.11.0\nv1.10.0'
run_launcher 0
assert_contains 'version=two ' "$stdout_file"
assert_no_stderr
assert_equal 'v1.11.0' "$(cat "$tag_file")"
cmp -s "$PLUGIN_SOURCE" "$cache_file" || fail 'update cache differs from downloaded plugin'

gh_count=$(line_count "$GH_LOG")
curl_count=$(line_count "$CURL_LOG")
export GH_TAGS=v1.12.0
run_launcher 0
assert_contains 'version=two ' "$stdout_file"
assert_equal "$gh_count" "$(line_count "$GH_LOG")"
assert_equal "$curl_count" "$(line_count "$CURL_LOG")"

cp "$cache_file" "$temp/known-good.sh"
printf '0\n' > "$check_file"
export GH_TAGS=v2.0.0 CURL_FAIL=1
run_launcher 0
assert_contains 'version=two ' "$stdout_file"
assert_no_stderr
cmp -s "$temp/known-good.sh" "$cache_file" || fail 'failed download replaced the known-good cache'

gh_count=$(line_count "$GH_LOG")
curl_count=$(line_count "$CURL_LOG")
unset CURL_FAIL
export GH_TAGS=v3.0.0
run_launcher 0
assert_contains 'version=two ' "$stdout_file"
assert_equal "$gh_count" "$(line_count "$GH_LOG")"
assert_equal "$curl_count" "$(line_count "$CURL_LOG")"

printf '0\n' > "$check_file"
export GH_TAGS=v2.1.0 CURL_INVALID=1
run_launcher 0
assert_contains 'version=two ' "$stdout_file"
assert_no_stderr
cmp -s "$temp/known-good.sh" "$cache_file" || fail 'invalid shell replaced the known-good cache'
unset CURL_INVALID
curl_count=$(line_count "$CURL_LOG")

printf '0\n' > "$check_file"
export GH_TAGS=v1.0.0
run_launcher 0
assert_contains 'version=two ' "$stdout_file"
assert_equal 'v1.11.0' "$(cat "$tag_file")"
assert_equal "$curl_count" "$(line_count "$CURL_LOG")"

missing_gh_data="$temp/missing-gh-data"
export SWIFTBAR_PLUGIN_DATA_PATH=$missing_gh_data
run_with_missing_tool gh 0
assert_stdout $'GitHub unavailable | color=red\n---\nGitHub CLI (gh) not found. Add gh to SwiftBar\x27s PATH.\n'
assert_no_stderr

export SWIFTBAR_PLUGIN_DATA_PATH=$temp/missing-jq-data
run_with_missing_tool jq 1 open-reviews
assert_stdout ''
assert_contains "jq not found. Add jq to SwiftBar's PATH." "$stderr_file"

missing_curl_data="$temp/missing-curl-data"
export SWIFTBAR_PLUGIN_DATA_PATH=$missing_curl_data
run_with_missing_tool curl 1 open-reviews
assert_stdout ''
assert_contains "curl not found. Add curl to SwiftBar's PATH." "$stderr_file"

fresh_data="$temp/fresh-data"
export SWIFTBAR_PLUGIN_DATA_PATH=$fresh_data GH_FAIL=1 GH_TAGS=v1.0.0
run_launcher 0
assert_stdout $'GitHub unavailable | color=red\n---\nCould not check GitHub for a plugin version. Check your connection and try again.\n'
assert_no_stderr
assert_absent gh-secret "$stdout_file"
assert_absent gh-secret "$stderr_file"

run_launcher 1 open-reviews
assert_stdout ''
assert_contains 'Could not check GitHub for a plugin version' "$stderr_file"
assert_absent gh-secret "$stderr_file"

unset GH_FAIL
export GH_TAGS=$'main\nv1.2.3-rc.1\nlatest'
run_launcher 1 open-reviews
assert_stdout ''
assert_contains 'No stable plugin version is available yet.' "$stderr_file"
assert_equal "$curl_count" "$(line_count "$CURL_LOG")"

dev_checkout="$temp/dev-checkout"
dev_plugins="$temp/dev-plugins"
mkdir -p "$dev_checkout" "$dev_plugins"
cp "$root/swiftbar-github-dev.3m.sh" "$dev_checkout/swiftbar-github-dev.3m.sh"
cat > "$dev_checkout/plugin.sh" <<'SH'
#!/bin/bash
printf 'dev=%s path=%s args=%s\n' "$SWIFTBAR_GITHUB_DEV" "$SWIFTBAR_PLUGIN_PATH" "$*"
SH
dev_link="$dev_plugins/swiftbar-github-dev.3m.sh"
ln -s ../dev-checkout/swiftbar-github-dev.3m.sh "$dev_link"
unset SWIFTBAR_PLUGIN_PATH SWIFTBAR_PLUGIN_DATA_PATH
export SWIFTBAR_GITHUB_DEV=0
if bash "$dev_link" mark-read > "$stdout_file" 2> "$stderr_file"; then
  status=0
else
  status=$?
fi
[[ $status -eq 0 ]] || fail "development launcher exited $status"
assert_stdout "dev=1 path=$dev_link args=mark-read"$'\n'
assert_no_stderr

printf 'launcher tests passed\n'
