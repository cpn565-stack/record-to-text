#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
OUTPUT_PATH="${2:-${PROJECT_DIR}/dist/record-to-text.dmg}"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  print -u2 "Usage: $0 <record-to-text.app> [output.dmg]"
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/record-to-text-dmg.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

ditto "${APP_PATH}" "${STAGING_DIR}/record-to-text.app"
ln -s /Applications "${STAGING_DIR}/Applications"
rm -f "${OUTPUT_PATH}"

hdiutil create \
  -volname "record-to-text" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_PATH}"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign \
    --force \
    --timestamp \
    --sign "${DEVELOPER_ID_APPLICATION}" \
    "${OUTPUT_PATH}"
else
  print "Created unsigned DMG; set DEVELOPER_ID_APPLICATION for a release artifact."
fi

print "Created ${OUTPUT_PATH}"
