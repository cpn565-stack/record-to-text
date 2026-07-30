#!/bin/zsh
set -euo pipefail

VERSION="${1:-}"
DMG_PATH="${2:-}"

if [[ -z "${VERSION}" || -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
  print -u2 "Usage: $0 <version> <record-to-text.dmg>"
  exit 1
fi
if [[ "${DMG_PATH}" != *.dmg ]]; then
  print -u2 "Release artifact must be a .dmg."
  exit 1
fi

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
