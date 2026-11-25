#!/usr/bin/env bash
set -e
installer=$(mktemp)
trap 'rm -f -- "$installer"' EXIT
curl -fsSL https://raw.githubusercontent.com/PhoenixxZ2023/VPS-MANAGER/main/install.sh -o "$installer"
bash "$installer" "$@"
