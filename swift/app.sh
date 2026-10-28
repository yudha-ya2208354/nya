#!/bin/sh
# Package ./nya into a signed .app bundle so Apple will hand it the Private Cloud Compute entitlement.
# usage: ./app.sh <codesign identity> [mobileprovision]
#   e.g. ./app.sh "Apple Development: you@example.com (TEAMID)" ~/Downloads/nYa.provision
#
# A real identity + a profile carrying com.apple.developer.private-cloud-compute are mandatory.
# Ad-hoc signing (-) gets the process SIGKILLed: the entitlement is in the plist but not backed by
# a profile Apple issued. On-device /fm needs none of this — ./build.sh && ./nya is enough.
set -e
cd "$(dirname "$0")"
ID="${1:?usage: ./app.sh <codesign identity> [provision]}"
PROV="$2"
A=out/Nya.app

[ -x nya ] || { echo "./nya missing — run ./build.sh first"; exit 1; }
rm -rf "$A"
mkdir -p "$A/Contents/MacOS"
cp nya "$A/Contents/MacOS/nya"

cat >"$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>nya</string>
  <key>CFBundleIdentifier</key><string>dev.nya.harness</string>
  <key>CFBundleName</key><string>Nya</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST

cat >out/nya.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.private-cloud-compute</key><true/>
</dict></plist>
ENT

[ -n "$PROV" ] && cp "$PROV" "$A/Contents/embedded.mobileprovision"

[ -n "$PROV" ] || echo "! no profile given — Apple will SIGKILL the process (137) even though signing succeeds"
[ "$ID" = "-" ] && echo "! ad-hoc identity '-' cannot carry a PCC entitlement — pass a real one"

codesign --force --sign "$ID" --entitlements out/nya.entitlements "$A"
codesign -d --entitlements :- "$A" 2>/dev/null | grep -q private-cloud-compute \
  && echo "✓ signed $A with the PCC entitlement" \
  || { echo "✗ entitlement did not survive signing"; exit 1; }
# exec the embedded binary — keeps your TTY, which `open` would not
echo "  run: \"$A/Contents/MacOS/nya\"  then /pcc"
