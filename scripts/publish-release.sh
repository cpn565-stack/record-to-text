#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/Config/version.env"

if (( $# == 1 )); then
  VERSION="${MARKETING_VERSION}"
  DMG_PATH="$1"
else
  VERSION="${1:-${MARKETING_VERSION}}"
  DMG_PATH="${2:-}"
fi

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
  print -u2 "Usage: $0 [version] <record-to-text.dmg>"
  exit 1
fi
if [[ "${VERSION}" != "${MARKETING_VERSION}" ]]; then
  print -u2 "Release version ${VERSION} does not match Config/version.env ${MARKETING_VERSION}."
  exit 1
fi
if [[ "${DMG_PATH}" != *.dmg ]]; then
  print -u2 "Release artifact must be a .dmg."
  exit 1
fi

"${SCRIPT_DIR}/check-version.sh"
gh auth status
hdiutil verify "${DMG_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

CHECKSUM_PATH="${DMG_PATH}.sha256"
shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"

gh release create "v${VERSION}" \
  "${DMG_PATH}" \
  "${CHECKSUM_PATH}" \
  --draft \
  --generate-notes \
  --title "record-to-text v${VERSION}"
