#!/usr/bin/env bash
# Usage: .github/bump.sh <sure_version>
# Points the add-on at a Sure release; the add-on half of the version stays.
set -euo pipefail
v=$1
[[ "$v" =~ ^[0-9]+(\.[0-9]+)*(-hotfix\.[0-9]+)?$ ]] || { echo "Invalid version: $v" >&2; exit 1; }
addon=$(grep -oP '(?<=^version: )[^-]+' sure/config.yaml)
sed -i "s/^ARG SURE_VERSION=.*/ARG SURE_VERSION=${v}/" sure/Dockerfile
sed -i "s/^version: .*/version: ${addon}-${v}/" sure/config.yaml
