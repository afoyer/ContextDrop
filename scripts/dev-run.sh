#!/bin/zsh
# Build Debug, copy to build/Run (fresh path for mDNSResponder's Bonjour allow-list cache), launch named instances.
# Usage: scripts/dev-run.sh Alice [Bob ...]
set -e
cd "$(dirname "$0")/.."
xcodebuild -project ContextDrop.xcodeproj -scheme ContextDrop -configuration Debug -derivedDataPath build/DerivedData build -quiet
pkill -f "build/Run/ContextDrop.app/Contents/MacOS/ContextDrop" || true
rm -rf build/Run && mkdir -p build/Run
cp -R build/DerivedData/Build/Products/Debug/ContextDrop.app build/Run/
for name in "${@:-Alice}"; do
  open -n build/Run/ContextDrop.app --args -ContextDrop.displayName "$name"
  sleep 1.5
done
echo "Running: $*  (logs: log stream --info --predicate 'subsystem == \"edu.cmu.hackathon.ContextDrop\"')"
