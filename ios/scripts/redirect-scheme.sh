#!/bin/sh
# Registers the Bluesky sign-in redirect's URL scheme in the built Info.plist (PROTOCOL.md §12.7
# step 6, PRODUCT.md §5), derived from the redirect itself so a fork can never register one scheme
# and redirect to another.
#
# Why derive instead of a third setting: the system browser hands the callback back only through a
# scheme the app registered. A fork that set TGS_ATPROTO_REDIRECT and registered a stale scheme sent
# people to Bluesky and never got them back — the same hang as the original `Continue` bug, with
# only the 10-minute timeout as a way out. So the scheme is read off the redirect, and the pair is
# held to the rule bsky.social enforces (§12.7: a native redirect's scheme is the client_id's host
# reversed) here, at build time, instead of failing at someone's consent page.
#
# Reads what the app reads at runtime (AtprotoClientConfig.fromBundle): TGSAtprotoClientId and
# TGSAtprotoRedirect from the processed Info.plist. Both empty: the reference client, whose scheme
# is the literal in project.yml, left as it is. Anything else must be a complete, consistent pair.
#
# Usage: redirect-scheme.sh <Info.plist>   (the build phase passes $TARGET_BUILD_DIR/$INFOPLIST_PATH)
set -eu

plist=${1:?usage: redirect-scheme.sh <Info.plist>}
pb=/usr/libexec/PlistBuddy

read_key() { "$pb" -c "Print :$1" "$plist" 2>/dev/null | tr -d '[:space:]' || true; }

id=$(read_key TGSAtprotoClientId)
redirect=$(read_key TGSAtprotoRedirect)

fail() { echo "error: $1 (ios/Secrets.xcconfig, PROTOCOL §12.7)" >&2; exit 1; }

if [ -z "$id" ] && [ -z "$redirect" ]; then
    echo "redirect-scheme: reference client, scheme $("$pb" -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$plist")"
    exit 0
fi
[ -n "$id" ] || fail "TGS_ATPROTO_REDIRECT is set but TGS_ATPROTO_CLIENT_ID is not; set both or neither"
[ -n "$redirect" ] || fail "TGS_ATPROTO_CLIENT_ID is set but TGS_ATPROTO_REDIRECT is not; set both or neither"

case "$redirect" in
    *:*) scheme=${redirect%%:*} ;;
    *) fail "TGS_ATPROTO_REDIRECT '$redirect' has no scheme" ;;
esac
[ -n "$scheme" ] || fail "TGS_ATPROTO_REDIRECT '$redirect' has no scheme"

# The client_id's host, reversed: https://tgsocial.example.com/x.json -> com.example.tgsocial.
host=$(printf '%s' "$id" | sed -nE 's#^[Hh][Tt][Tt][Pp][Ss]://([^/:?#]+).*#\1#p' | tr '[:upper:]' '[:lower:]')
[ -n "$host" ] || fail "TGS_ATPROTO_CLIENT_ID '$id' is not an https URL"
reversed=$(printf '%s' "$host" | awk -F. '{ for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? "." : "") }')
[ "$scheme" = "$reversed" ] || fail "TGS_ATPROTO_REDIRECT's scheme '$scheme' must be the client_id host reversed, '$reversed'"

"$pb" -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $scheme" "$plist"
echo "redirect-scheme: registered $scheme"
