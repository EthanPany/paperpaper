#!/bin/sh
# Set the build number for Xcode Cloud builds so it is always higher than
# previously uploaded builds (highest manual upload was 4).
# https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
agvtool new-version -all $((CI_BUILD_NUMBER + 10))
