#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-}"
PRODUCT="teaway"
BUNDLE_ID="com.soundadam.teaway.cli"
EXPECTED_TEAM_ID="${TEAWAY_EXPECTED_TEAM_ID:-${TEA_EXPECTED_TEAM_ID:-D8UV6MLRN7}}"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "usage: $0 VERSION"
    exit 2
fi

identity="${TEAWAY_CODESIGN_IDENTITY:-${TEA_CODESIGN_IDENTITY:-}}"
if [[ -z "$identity" ]]; then
    identities=("${(@f)$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F\" '/Apple Development:/ {print $2}')}" )
    identities=("${(@)identities:#}")
    if (( ${#identities[@]} != 1 )); then
        print -u2 "teaway: set TEAWAY_CODESIGN_IDENTITY; expected exactly one Apple Development identity"
        exit 1
    fi
    identity="$identities[1]"
fi

arch=$(/usr/bin/uname -m)
case "$arch" in
    arm64|x86_64) ;;
    *)
        print -u2 "teaway: unsupported development archive architecture: $arch"
        exit 1
        ;;
esac

/usr/bin/mkdir -p "$ROOT/.build/release"
( cd "$ROOT" && /usr/bin/go test ./... )
( cd "$ROOT" && /usr/bin/go build -o "$ROOT/.build/release/$PRODUCT" . )

built_version=$("$ROOT/.build/release/$PRODUCT" version)
if [[ "$built_version" != "$PRODUCT $VERSION" ]]; then
    print -u2 "teaway: package version $VERSION does not match binary version: $built_version"
    exit 1
fi

dist="$ROOT/dist"
stage="$dist/$PRODUCT-$VERSION-macos-$arch-development"
archive="$stage.zip"
verify_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/teaway-verify.XXXXXX")
trap '/bin/rm -rf "$verify_root" "$stage"' EXIT

/bin/rm -rf "$stage" "$archive" "$archive.sha256"
/bin/mkdir -p "$stage/bin"
/usr/bin/install -m 0755 "$ROOT/.build/release/$PRODUCT" "$stage/bin/$PRODUCT"
/usr/bin/install -m 0644 "$ROOT/README.md" "$stage/README.md"
/usr/bin/install -m 0644 "$ROOT/NOTICE" "$stage/NOTICE"

/usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --identifier "$BUNDLE_ID" \
    --sign "$identity" \
    "$stage/bin/$PRODUCT"
/usr/bin/codesign --verify --strict --verbose=2 "$stage/bin/$PRODUCT"

signature_details=$(/usr/bin/codesign -dvvv "$stage/bin/$PRODUCT" 2>&1)
team_id=$(print -r -- "$signature_details" | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2}')
signing_authority=$(print -r -- "$signature_details" | /usr/bin/awk -F= '$1 == "Authority" && !seen {print $2; seen=1}')
signed_identifier=$(print -r -- "$signature_details" | /usr/bin/awk -F= '$1 == "Identifier" {print $2}')
if [[ "$signing_authority" != "Apple Development:"* || -z "$team_id" ]]; then
    print -u2 "teaway: development archives require an Apple Development signature with a Team ID"
    exit 1
fi
if [[ "$team_id" != "$EXPECTED_TEAM_ID" ]]; then
    print -u2 "teaway: selected signing identity belongs to Team $team_id, expected $EXPECTED_TEAM_ID"
    exit 1
fi
if [[ "$signed_identifier" != "$BUNDLE_ID" ]]; then
    print -u2 "teaway: signed identifier is $signed_identifier, expected $BUNDLE_ID"
    exit 1
fi
if ! /usr/bin/grep -Eq 'flags=.*\(runtime' <<< "$signature_details"; then
    print -u2 "teaway: signed executable is missing the hardened-runtime flag"
    exit 1
fi

{
    print "product=$PRODUCT"
    print "version=$VERSION"
    print "architecture=$arch"
    print "bundle_identifier=$BUNDLE_ID"
    print "team_identifier=$team_id"
    print "signing_class=Apple Development"
    print "distribution=local-development-only"
    print "notarized=false"
    print "homebrew_public_asset=false"
} > "$stage/DEVELOPMENT-MANIFEST.txt"

/usr/bin/ditto -c -k --norsrc --keepParent "$stage" "$archive"
(
    cd "$dist"
    /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)

/usr/bin/ditto -x -k "$archive" "$verify_root"
verified_binary="$verify_root/${stage:t}/bin/$PRODUCT"
/usr/bin/codesign --verify --strict --verbose=2 "$verified_binary"
verified_version=$("$verified_binary" version)
if [[ "$verified_version" != "$PRODUCT $VERSION" ]]; then
    print -u2 "teaway: archived binary version mismatch: $verified_version"
    exit 1
fi
verified_signature_details=$(/usr/bin/codesign -dvvv "$verified_binary" 2>&1)
if ! /usr/bin/grep -Fq "Identifier=$BUNDLE_ID" <<< "$verified_signature_details" \
    || ! /usr/bin/grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$verified_signature_details" \
    || ! /usr/bin/grep -Eq 'flags=.*\(runtime' <<< "$verified_signature_details"; then
    print -u2 "teaway: archived signature metadata did not survive round-trip verification"
    exit 1
fi

print "$archive"
print "$archive.sha256"
print "development signing: Apple Development ($team_id)"
print "public distribution: blocked; Apple Development is not Developer ID"
