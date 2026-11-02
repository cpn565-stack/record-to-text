#!/bin/zsh
set -euo pipefail

# Lossless filesystem compression: keep every codec, resource and executable
# byte. Run on a staged bundle, before installation; never on a running App.
APP_PATH="${1:-}"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}/Contents" || -L "${APP_PATH}" ]]; then
  print -u2 "Usage: $0 <staged-record-to-text.app>"
  exit 1
fi
APP_PATH="${APP_PATH:A}"
if [[ "${APP_PATH:t}" != "record-to-text.app" ]]; then
  print -u2 "Expected a staged record-to-text.app bundle."
  exit 1
fi
if [[ "${APP_PATH}" == /Applications/* || "${APP_PATH}" == ${HOME}/Applications/* ]]; then
  print -u2 "Compact a staged copy, then install it after quitting the App."
  exit 1
fi

BEFORE_KIB="$(du -sk "${APP_PATH}" | awk '{print $1}')"
STAGING_DIR="$(mktemp -d "${APP_PATH:h}/.compact-app.XXXXXX")"
cleanup() {
  # Restore the original if swapping the verified copy failed.
  if [[ ! -e "${APP_PATH}" && -d "${STAGING_DIR}/original.app" ]]; then
    mv "${STAGING_DIR}/original.app" "${APP_PATH}"
  fi
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

ditto --hfsCompression "${APP_PATH}" "${STAGING_DIR}/record-to-text.app"
diff -qr "${APP_PATH}" "${STAGING_DIR}/record-to-text.app" >/dev/null
if [[ -f "${APP_PATH}/Contents/_CodeSignature/CodeResources" ]]; then
  codesign --verify --deep --strict "${STAGING_DIR}/record-to-text.app"
fi
AFTER_KIB="$(du -sk "${STAGING_DIR}/record-to-text.app" | awk '{print $1}')"
if (( AFTER_KIB < BEFORE_KIB )); then
  mv "${APP_PATH}" "${STAGING_DIR}/original.app"
  mv "${STAGING_DIR}/record-to-text.app" "${APP_PATH}"
  print "App disk usage: ${BEFORE_KIB} -> ${AFTER_KIB} KiB; file contents unchanged."
else
  print "App disk usage: ${BEFORE_KIB} KiB; no further compression available."
fi
