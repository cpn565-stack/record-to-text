#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/Config/version.env"

if ! xcodebuild -version >/dev/null 2>&1; then
  print -u2 "Full Xcode is required for a release/Universal verification build."
  exit 1
fi

VERSION="${VERSION:-${MARKETING_VERSION}}" \
BUILD_NUMBER="${BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER}}" \
CONFIGURATION=release \
UNIVERSAL=1 \
ADHOC_SIGN=0 \
  "${PROJECT_DIR}/scripts/build-app.sh"

REQUIRE_UNIVERSAL=1 \
ALLOW_UNSIGNED=1 \
  "${PROJECT_DIR}/scripts/verify-release.sh" \
  "${PROJECT_DIR}/dist/record-to-text.app"
