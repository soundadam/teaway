#!/bin/sh
# Render the Charm client views to docs/images/. Requires freeze:
#   go install github.com/charmbracelet/freeze@latest
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
freeze="${FREEZE:-$(command -v freeze || true)}"
if [ -z "$freeze" ] && [ -x "$HOME/go/bin/freeze" ]; then
  freeze="$HOME/go/bin/freeze"
fi
if [ -z "$freeze" ]; then
  echo "install freeze: go install github.com/charmbracelet/freeze@latest" >&2
  exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
go run ./scripts/render-client menu >"$tmp/menu.ansi"
go run ./scripts/render-client shutdown >"$tmp/shutdown.ansi"
mkdir -p docs/images
for pair in menu:client shutdown:shutdown; do
  src="${pair%%:*}"
  dst="${pair##*:}"
  "$freeze" -x "cat $tmp/${src}.ansi" \
    --window --border.radius 8 --padding 20 --margin 28 \
    --background "#1A1A2E" --font.size 15 --line-height 1.3 \
    -o "docs/images/${dst}.png"
  sips --resampleWidth 1280 "docs/images/${dst}.png" >/dev/null
done
