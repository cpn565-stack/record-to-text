#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  print "Usage: DEVELOPER_ID_APPLICATION='Developer ID Application: …' $0 <app>"
  exit 0
fi

APP_PATH="${1:-}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  print -u2 "Provide an existing .app path."
  exit 1
fi
if [[ -z "${IDENTITY}" ]]; then
  print -u2 "DEVELOPER_ID_APPLICATION is required; refusing to create a fake release signature."
  exit 1
fi

if [[ -d "${APP_PATH}/Contents/Helpers" ]]; then
  for helper_bin in "${APP_PATH}/Contents/Helpers"/*(N); do
    if [[ -f "${helper_bin}" && ! -L "${helper_bin}" && -x "${helper_bin}" ]]; then
      codesign \
        --force \
        --timestamp \
        --options runtime \
        --sign "${IDENTITY}" \
        "${helper_bin}"
    fi
  done
fi

codesign \
  --force \
  --timestamp \
  --options runtime \
  --entitlements "${PROJECT_DIR}/Config/record-to-text.entitlements" \
  --sign "${IDENTITY}" \
  "${APP_PATH}"

if [[ "${COMPACT_APP:-0}" == "1" ]]; then
  "${SCRIPT_DIR}/compact-app.sh" "${APP_PATH}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
