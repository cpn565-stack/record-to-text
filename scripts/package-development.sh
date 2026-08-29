#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION_FILE="${PROJECT_DIR}/Config/version.env"

source "${VERSION_FILE}"
"${SCRIPT_DIR}/check-version.sh"

VERSION="${VERSION:-${MARKETING_VERSION}}"
BUILD_NUMBER="${BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER}}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/record-to-text.app"
DMG_PATH="${DIST_DIR}/record-to-text-${VERSION}-development.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"

VERSION="${VERSION}" \
BUILD_NUMBER="${BUILD_NUMBER}" \
CONFIGURATION=release \
UNIVERSAL=0 \
ADHOC_SIGN=0 \
  "${SCRIPT_DIR}/build-app.sh"

"${SCRIPT_DIR}/create-dmg.sh" "${APP_PATH}" "${DMG_PATH}"

EXPECTED_VERSION="${VERSION}" \
EXPECTED_BUILD_NUMBER="${BUILD_NUMBER}" \
ALLOW_UNSIGNED=1 \
CHECK_APP_SIZE=1 \
MAX_APP_BYTES="${MAX_APP_BYTES:-157286400}" \
  "${SCRIPT_DIR}/verify-release.sh" "${APP_PATH}" "${DMG_PATH}"

shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"

print "Development delivery artifacts:"
print "  ${DMG_PATH}"
print "  ${CHECKSUM_PATH}"
print "This artifact is unsigned and intended for testing, not public Stable distribution."
