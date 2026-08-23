#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
REPOSITORY="${1:-}"
VERSION="${2:-}"
SHA256="${3:-}"
LICENSE="${4:-}"
OUTPUT="${5:-$ROOT/packaging/Formula/teaway.rb}"
TEMPLATE="$ROOT/packaging/Formula/teaway.rb.in"
VERSION_SOURCE="$ROOT/internal/version/version.go"

if [[ ! "$REPOSITORY" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]]; then
    print -u2 "usage: $0 OWNER/REPOSITORY VERSION SHA256 SPDX-LICENSE [OUTPUT]"
    exit 2
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "teaway: invalid version: $VERSION"
    exit 2
fi
source_version=$(/usr/bin/awk -F\" '/^const Current = / {print $2}' "$VERSION_SOURCE")
if [[ -z "$source_version" || "$VERSION" != "$source_version" ]]; then
    print -u2 "teaway: Formula version $VERSION does not match source version ${source_version:-unknown}"
    exit 2
fi
if [[ ! "$SHA256" =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 "teaway: SHA-256 must be 64 lowercase hexadecimal characters"
    exit 2
fi
if [[ ! "$LICENSE" =~ '^[A-Za-z0-9.+-]+$' ]]; then
    print -u2 "teaway: provide one SPDX license identifier"
    exit 2
fi
if [[ "$OUTPUT" == "$TEMPLATE" ]]; then
    print -u2 "teaway: refusing to overwrite the Formula template"
    exit 2
fi

content=$(<"$TEMPLATE")
content="${content//@REPOSITORY@/$REPOSITORY}"
content="${content//@VERSION@/$VERSION}"
content="${content//@SHA256@/$SHA256}"
content="${content//@LICENSE@/$LICENSE}"

output_dir="${OUTPUT:h}"
/bin/mkdir -p "$output_dir"
temporary=$(/usr/bin/mktemp "$output_dir/.teaway.rb.XXXXXX")
trap '/bin/rm -f "$temporary"' EXIT
print -r -- "$content" > "$temporary"
/bin/chmod 0644 "$temporary"
/bin/mv "$temporary" "$OUTPUT"
trap - EXIT
print "$OUTPUT"
