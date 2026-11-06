#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for script in "$root"/*.sh "$root"/tests/*.sh; do bash -n "$script"; done
shellcheck "$root"/*.sh "$root"/tests/*.sh
for test in "$root"/tests/*.test.sh; do bash "$test"; done
