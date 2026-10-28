#!/bin/sh
# nya (python edition) still needs one Swift compile: FoundationModels has no
# Objective-C surface, so the model call cannot be made from Python at all.
# build.sh then: python3 nya.py
set -e
cd "$(dirname "$0")"
swiftc -swift-version 5 -target arm64-apple-macosx27.0 shim.swift -o shim
echo "✓ built ./shim — run: python3 nya.py"
