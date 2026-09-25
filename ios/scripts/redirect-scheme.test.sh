#!/bin/sh
# Measures scripts/redirect-scheme.sh against Info.plists shaped like the build's: the scheme it
# registers, and that it refuses the fork configurations that would ship a sign-in that never
# comes back (PROTOCOL §12.7 step 6). Run by `make test`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
pb=/usr/libexec/PlistBuddy
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0; failed=0

# plist <client id> <redirect>: the processed Info.plist as project.yml writes it.
plist() {
    f="$tmp/Info-$pass-$failed.plist"
    rm -f "$f"
    "$pb" -c "Add :TGSAtprotoClientId string $1" -c "Add :TGSAtprotoRedirect string $2" \
          -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" \
          -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
          -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ca.lucianlabs" "$f" >/dev/null
    echo "$f"
}

# expect <name> <client id> <redirect> <scheme | FAIL>
expect() {
    f=$(plist "$2" "$3")
    if sh "$here/redirect-scheme.sh" "$f" >/dev/null 2>"$tmp/err"; then
        got=$("$pb" -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$f")
    else
        got=FAIL
    fi
    if [ "$got" = "$4" ]; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "not ok - $1: want $4, got $got $(cat "$tmp/err")"; fi
}

expect "reference client (both unset)" "" "" ca.lucianlabs
expect "fork: scheme read off the redirect" \
    "https://tgsocial.example.com/client-metadata.json" "com.example.tgsocial:/tgsocial/oauth/callback" com.example.tgsocial
expect "fork: host case does not matter" \
    "https://TGSocial.Example.com/client-metadata.json" "com.example.tgsocial:/cb" com.example.tgsocial
expect "fork: redirect without client_id" "" "com.example.tgsocial:/tgsocial/oauth/callback" FAIL
expect "fork: client_id without redirect" "https://tgsocial.example.com/client-metadata.json" "" FAIL
expect "fork: scheme is not the host reversed" \
    "https://tgsocial.example.com/client-metadata.json" "com.example:/tgsocial/oauth/callback" FAIL
expect "fork: redirect with no scheme" "https://tgsocial.example.com/client-metadata.json" "tgsocial/oauth/callback" FAIL
expect "fork: client_id not https" "http://tgsocial.example.com/client-metadata.json" "com.example.tgsocial:/cb" FAIL

# A plist with no Bluesky keys at all (an older project.yml) is the reference client.
f="$tmp/bare.plist"
"$pb" -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
      -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ca.lucianlabs" "$f" >/dev/null
if sh "$here/redirect-scheme.sh" "$f" >/dev/null 2>&1 && [ "$("$pb" -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$f")" = ca.lucianlabs ]; then
    pass=$((pass + 1)); else failed=$((failed + 1)); echo "not ok - no keys: reference scheme kept"; fi

echo "redirect-scheme: $pass pass, $failed fail"
[ "$failed" -eq 0 ]
