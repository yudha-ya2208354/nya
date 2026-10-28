#!/bin/sh
# nya needs the macOS 27 SDK only (no Xcode). ./build.sh then ./nya
set -e
cd "$(dirname "$0")"
swiftc -swift-version 5 -target arm64-apple-macosx27.0 Sources/nya/*.swift -o nya
echo "✓ built ./nya"
