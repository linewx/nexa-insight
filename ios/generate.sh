#!/usr/bin/env bash
# Generate NexaInsight.xcodeproj from project.yml.
# xcodegen 2.46 emits objectVersion 77 (Xcode 16); Xcode 15.4 needs <=56.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate
sed -i '' 's/objectVersion = 77;/objectVersion = 56;/' NexaInsight.xcodeproj/project.pbxproj
echo "Generated NexaInsight.xcodeproj (objectVersion pinned to 56)"
