#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p bin
work=$(mktemp -d bin/.build.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags="-s -w" -o "$work/turboproxy-linux-$arch" server.go
done
(cd "$work" && sha256sum turboproxy-linux-* > SHA256SUMS)
mv -- "$work"/* bin/
