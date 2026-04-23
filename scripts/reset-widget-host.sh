#!/bin/bash
# Purges chronod's cached paperpaper state when the widget kind list changes.
#
# Apple bug (see https://developer.apple.com/forums/thread/746574): changing a
# widget's `kind` id poisons
#   ~/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql
# so chronod thinks the extension exists but never re-ingests its new kind
# list — every lookup hits extensionNotFound and the widget stays on
# placeholder. There is no public API to invalidate this.
#
# Usage: ./scripts/reset-widget-host.sh
# Then: build & run paperpaper from Xcode, remove the widget from Desktop,
# re-add it from the widget gallery.

set -e

DB="$HOME/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

echo "1/4 Killing chronod..."
killall -9 chronod 2>/dev/null || true
sleep 2

echo "2/4 Removing paperpaper rows from chronod SQLite..."
sqlite3 "$DB" "DELETE FROM WidgetMetadata WHERE BundleIdentifier LIKE '%paperpaper%';"
sqlite3 "$DB" "DELETE FROM ExtensionMetadata WHERE bundleIdentifier LIKE '%paperpaper%';"

echo "3/4 Clearing chronod caches..."
rm -rf "$HOME/Library/Caches/com.apple.chrono/snapshot-cache"/* 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.apple.chrono/widget-relevance-cache"/* 2>/dev/null || true

echo "4/4 Re-registering the current Debug build with LaunchServices..."
APP=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData"/paperpaper-*/Build/Products/Debug/paperpaper.app 2>/dev/null | head -1)
if [ -n "$APP" ]; then
    "$LSREGISTER" -f -R -trusted "$APP"
    echo "Registered: $APP"
else
    echo "Warning: no built paperpaper.app found in DerivedData. Build once in Xcode, then re-run this."
fi

echo
echo "Done. Now:"
echo "  - Build & run paperpaper from Xcode (⌘R)."
echo "  - On the Desktop, remove any paperpaper widget, then re-add it from the gallery."
echo "  - Set a wallpaper. Widget should render."
